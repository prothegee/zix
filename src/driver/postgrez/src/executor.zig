//! Batching executor: a bounded intake queue plus worker threads that run
//! database round trips off the caller's thread.
//!
//! Note:
//! - Generic over the consumer Job type and the count of prepared SQL slots
//!   per connection. The driver owns the queue, the workers, the pool, the
//!   per-connection prepared-statement cache, and the batch lifecycle. The
//!   consumer owns only the Job type and the run_batch body (pipeline the
//!   prepared statements, then act on the results).
//! - A worker drains up to batch_max jobs per wakeup and hands them to
//!   run_batch on one connection acquired from the internal Pool, so several
//!   jobs share one round trip (Statement.sendRows / awaitRows).
//! - Prepared statements belong to the pooled connection: a side table maps
//!   each live connection to its statement slots, cleared when the connection
//!   is discarded after a transport failure.

const std = @import("std");
const lib = @import("lib.zig");
const conn_mod = @import("conn.zig");
const statement_mod = @import("statement.zig");

const Conn = conn_mod.Conn;
const Statement = statement_mod.Statement;

// --------------------------------------------------------- //

/// Worker ceiling. A fleet far wider than the CPU budget degenerates into
/// single-job batches (each job pays a full round trip plus a context
/// switch), so the auto sizing never exceeds this.
const WORKER_CAP = 128;

/// Batch-fill histogram width (diagnostics). batch_max must not exceed it.
const FILL_BUCKETS = 64;

/// Auto worker count from the CPU count and a capacity hint: hint/2 bounded
/// by 8 workers per CPU, floored at 16, capped at WORKER_CAP. A zero hint
/// falls back to the floor.
///
/// Param:
/// cpus - usize (available CPU count)
/// hint - usize (capacity hint, e.g. a max-connection budget, 0 = unknown)
///
/// Return:
/// - usize (worker count)
pub fn sizeWorkers(cpus: usize, hint: usize) usize {
    if (hint == 0) return 16;

    const cpu_cap = @max(16, cpus * 8);

    return @min(@min(WORKER_CAP, cpu_cap), @max(16, hint / 2));
}

/// Diagnostic snapshot, read-and-reset (see Executor.snapshot).
pub const Stats = struct {
    /// Deepest the intake queue reached since the last snapshot.
    ring_high: usize = 0,
    /// Batches run since the last snapshot.
    batches: u64 = 0,
    /// Jobs run since the last snapshot.
    jobs: u64 = 0,
    /// Total batch wall time since the last snapshot (nanoseconds).
    batch_ns: u64 = 0,
    /// fill[k] = batches that drained k+1 jobs.
    fill: [FILL_BUCKETS]u64 = @splat(0),
};

/// Build a batching executor over a fresh internal Pool.
///
/// Note:
/// - Job is opaque to the driver: it carries whatever a request needs.
/// - statement_count is the number of distinct prepared SQL texts one
///   connection caches (index the slots with a plain enum or const).
pub fn Executor(comptime Job: type, comptime statement_count: usize) type {
    return struct {
        const Self = @This();

        /// Prepared statement slots of one pooled connection, cleared when
        /// the connection is discarded.
        const Table = struct {
            conn: ?*Conn = null,
            statements: [statement_count]?Statement = @splat(null),
        };

        /// Per-batch context passed to run_batch. Hands out prepared
        /// statements on the held connection and flags transport failure.
        pub const Batch = struct {
            executor: *Self,
            table: ?*Table,
            broken: bool = false,

            /// The prepared statement for slot on the held connection,
            /// prepared and cached on first use.
            ///
            /// Return:
            /// - *Statement, ready for sendRows / awaitRows / rows / exec
            /// - null when no connection was acquired, or the prepare failed
            ///   (a transport-level failure also marks the batch broken)
            pub fn statement(self: *Batch, slot: usize, sql: []const u8) ?*Statement {
                const table = self.table orelse return null;

                if (table.statements[slot]) |*ready| return ready;

                table.statements[slot] = table.conn.?.prepare(sql) catch |err| {
                    if (err != error.ServerError) self.broken = true;

                    return null;
                };

                return &table.statements[slot].?;
            }

            /// Flag a transport failure, so the driver discards this
            /// connection (and its cached statements) after the batch.
            pub fn markBroken(self: *Batch) void {
                self.broken = true;
            }

            /// Whether a connection was acquired for this batch. When false,
            /// every statement() returns null and run_batch should answer
            /// each job with an error.
            pub fn connected(self: *const Batch) bool {
                return self.table != null;
            }
        };

        pub const Options = struct {
            /// Runs one drained batch on the held connection. Owns each job's
            /// outcome (the response, side effect, or error).
            run_batch: *const fn (*Batch, []const Job) void,
            /// 0 = auto from the CPU count and max_conn_hint.
            workers: usize = 0,
            /// Capacity hint for auto sizing, ignored when workers is set.
            max_conn_hint: usize = 0,
            /// Intake queue depth, above the largest expected burst so
            /// shedding only guards true overload.
            queue_len: usize = 8192,
            /// Jobs one worker drains per wakeup, matches the connection
            /// max_pending_replies default.
            batch_max: usize = 16,
            /// Collect the diagnostic counters (see snapshot).
            stats: bool = false,
        };

        allocator: std.mem.Allocator,
        pool: lib.Pool,
        run_batch: *const fn (*Batch, []const Job) void,
        worker_count: usize,
        batch_max: usize,
        queue_len: usize,

        ring: []Job,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        ring_lock: std.atomic.Value(bool) = .init(false),
        pending: std.atomic.Value(u32) = .init(0),

        tables: []Table,
        table_lock: std.atomic.Value(bool) = .init(false),

        scratch: []Job,
        threads: []std.Thread,
        shutdown: std.atomic.Value(bool) = .init(false),

        stats_on: bool,
        stat_ring_high: std.atomic.Value(usize) = .init(0),
        stat_batches: std.atomic.Value(u64) = .init(0),
        stat_jobs: std.atomic.Value(u64) = .init(0),
        stat_batch_ns: std.atomic.Value(u64) = .init(0),
        stat_fill: [FILL_BUCKETS]std.atomic.Value(u64) = @splat(.init(0)),

        /// Build the executor: size the fleet, open the internal Pool, spawn
        /// the workers.
        ///
        /// Note:
        /// - config drives the Pool: this overrides pool_size and
        ///   process_queue_len from the computed worker count, the rest
        ///   (host, auth, tls, max_pending_replies, retries) is the caller's.
        ///
        /// Param:
        /// config - lib.Config (connection plus pool config, pool_size and process_queue_len are overridden)
        /// options - Options (run_batch is required, the rest have defaults)
        ///
        /// Return:
        /// - *Executor, deinit stops the workers and frees everything
        /// - error.BatchTooWide when batch_max exceeds the histogram width
        /// - allocation or Pool.init errors
        pub fn init(allocator: std.mem.Allocator, io: std.Io, config: lib.Config, options: Options) !*Self {
            if (options.batch_max == 0 or options.batch_max > FILL_BUCKETS) return error.BatchTooWide;

            const cpus = std.Thread.getCpuCount() catch 16;
            const workers = if (options.workers != 0) options.workers else sizeWorkers(cpus, options.max_conn_hint);

            var pool_config = config;
            pool_config.pool_size = workers;
            // A margin above the workers covers runInline callers (they
            // acquire from the same pool while every worker holds a slot).
            pool_config.process_queue_len = workers + 64;

            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const ring = try allocator.alloc(Job, options.queue_len);
            errdefer allocator.free(ring);

            const tables = try allocator.alloc(Table, workers);
            errdefer allocator.free(tables);
            for (tables) |*table| table.* = .{};

            const scratch = try allocator.alloc(Job, workers * options.batch_max);
            errdefer allocator.free(scratch);

            const threads = try allocator.alloc(std.Thread, workers);
            errdefer allocator.free(threads);

            self.* = .{
                .allocator = allocator,
                .pool = try lib.Pool.init(allocator, io, pool_config),
                .run_batch = options.run_batch,
                .worker_count = workers,
                .batch_max = options.batch_max,
                .queue_len = options.queue_len,
                .ring = ring,
                .tables = tables,
                .scratch = scratch,
                .threads = threads,
                .stats_on = options.stats,
            };
            errdefer self.pool.deinit();

            var spawned: usize = 0;
            errdefer self.stopWorkers(spawned);
            while (spawned < workers) : (spawned += 1) {
                self.threads[spawned] = try std.Thread.spawn(.{}, workerLoop, .{ self, spawned });
            }

            return self;
        }

        /// Stop the workers, close the connections, free everything. Callers
        /// must be quiescent: no submit or runInline in flight.
        pub fn deinit(self: *Self) void {
            self.stopWorkers(self.worker_count);

            // workers released every connection, statements are still live
            for (self.tables) |*table| {
                if (table.conn == null) continue;

                for (&table.statements) |*slot| {
                    if (slot.*) |*prepared| prepared.deinit();
                }
            }

            self.pool.deinit();
            self.allocator.free(self.threads);
            self.allocator.free(self.scratch);
            self.allocator.free(self.tables);
            self.allocator.free(self.ring);
            self.allocator.destroy(self);
        }

        // --------------------------------------------------------- //

        /// Queue one job. Called off the workers, never blocks.
        ///
        /// Return:
        /// - true when queued (a worker owns the outcome from here)
        /// - false when the queue is full (the caller sheds)
        pub fn submit(self: *Self, job: Job) bool {
            self.lockRing();
            if (self.count == self.queue_len) {
                self.unlockRing();

                return false;
            }
            self.ring[self.tail] = job;
            self.tail = (self.tail + 1) % self.queue_len;
            self.count += 1;
            const depth = self.count;
            self.unlockRing();

            if (self.stats_on) self.recordDepth(depth);

            _ = self.pending.fetchAdd(1, .release);
            wake(&self.pending, 1);

            return true;
        }

        /// Run one job synchronously on the calling thread, its outcome
        /// produced before returning. For work that cannot outlive the call
        /// (a response on a connection the caller is about to close): a
        /// worker-deferred write would race that close.
        ///
        /// Return:
        /// - true always (the job ran, success or error)
        pub fn runInline(self: *Self, job: Job) bool {
            var one = [_]Job{job};
            self.runBatch(one[0..1]);

            return true;
        }

        /// Read and reset the diagnostic counters. Zero-valued when stats
        /// were not enabled.
        pub fn snapshot(self: *Self) Stats {
            var out = Stats{
                .ring_high = self.stat_ring_high.swap(0, .monotonic),
                .batches = self.stat_batches.swap(0, .monotonic),
                .jobs = self.stat_jobs.swap(0, .monotonic),
                .batch_ns = self.stat_batch_ns.swap(0, .monotonic),
            };
            for (&self.stat_fill, 0..) |*bucket, index| out.fill[index] = bucket.swap(0, .monotonic);

            return out;
        }

        /// Workers currently spawned (diagnostics).
        pub fn workerCount(self: *const Self) usize {
            return self.worker_count;
        }

        // --------------------------------------------------------- //

        fn workerLoop(self: *Self, worker_id: usize) void {
            const scratch = self.scratch[worker_id * self.batch_max ..][0..self.batch_max];

            while (true) {
                scratch[0] = self.take() orelse return;

                var drained: usize = 1;
                while (drained < self.batch_max) : (drained += 1) {
                    scratch[drained] = self.tryTake() orelse break;
                }

                self.runBatch(scratch[0..drained]);
            }
        }

        /// Acquire a connection, run one batch, release or discard it.
        fn runBatch(self: *Self, jobs: []const Job) void {
            var batch = Batch{ .executor = self, .table = self.acquireBatch() };

            const started = if (self.stats_on) nowNanos() else 0;
            self.run_batch(&batch, jobs);

            self.finishBatch(&batch);

            if (self.stats_on) self.recordBatch(jobs.len, nowNanos() - started);
        }

        /// Take a connection and claim its statement table, returning the
        /// bound table. Null when the pool could not hand one over.
        fn acquireBatch(self: *Self) ?*Table {
            const pooled = self.pool.acquire() catch return null;

            const table = self.claimTable(pooled);
            if (table == null) self.pool.release(pooled);

            return table;
        }

        /// Give the connection back: release keeps it and its statements
        /// warm, discard (after a transport failure) destroys both.
        fn finishBatch(self: *Self, batch: *Batch) void {
            const table = batch.table orelse return;
            const pooled = table.conn.?;

            if (batch.broken) {
                for (&table.statements) |*slot| {
                    if (slot.*) |*prepared| prepared.deinit();

                    slot.* = null;
                }

                self.lockTables();
                table.conn = null;
                self.unlockTables();

                self.pool.discard(pooled);

                return;
            }

            self.pool.release(pooled);
        }

        /// The table already bound to conn, else a free one bound to it now.
        fn claimTable(self: *Self, pooled: *Conn) ?*Table {
            self.lockTables();
            defer self.unlockTables();

            var free_table: ?*Table = null;
            for (self.tables) |*table| {
                if (table.conn == pooled) return table;
                if (table.conn == null and free_table == null) free_table = table;
            }

            if (free_table) |table| {
                table.conn = pooled;

                return table;
            }

            return null;
        }

        // --------------------------------------------------------- //

        /// Blocking take of one job (the batch opener). Null on shutdown.
        fn take(self: *Self) ?Job {
            while (true) {
                if (self.shutdown.load(.acquire)) return null;

                const owed = self.pending.load(.acquire);
                if (owed == 0) {
                    waitZero(&self.pending);

                    continue;
                }
                if (self.pending.cmpxchgWeak(owed, owed - 1, .acq_rel, .acquire) != null) continue;

                return self.pop();
            }
        }

        /// Non-blocking take, fills the rest of a batch from what is queued.
        fn tryTake(self: *Self) ?Job {
            while (true) {
                const owed = self.pending.load(.acquire);
                if (owed == 0) return null;
                if (self.pending.cmpxchgWeak(owed, owed - 1, .acq_rel, .acquire) != null) continue;

                return self.pop();
            }
        }

        fn pop(self: *Self) Job {
            self.lockRing();
            const job = self.ring[self.head];
            self.head = (self.head + 1) % self.queue_len;
            self.count -= 1;
            self.unlockRing();

            return job;
        }

        fn stopWorkers(self: *Self, spawned: usize) void {
            self.shutdown.store(true, .release);

            // Defeat a lost wakeup: a worker that read shutdown as false and
            // is about to block in waitZero needs pending non-zero so its
            // expected-zero futex wait returns at once, then rechecks
            // shutdown. The wake handles workers already asleep. take()
            // checks shutdown before touching pending, so this credit is
            // never consumed as a job.
            _ = self.pending.fetchAdd(1, .release);
            wake(&self.pending, spawned);

            for (self.threads[0..spawned]) |thread| thread.join();
        }

        // --------------------------------------------------------- //

        fn recordDepth(self: *Self, depth: usize) void {
            var high = self.stat_ring_high.load(.monotonic);
            while (depth > high) {
                high = self.stat_ring_high.cmpxchgWeak(high, depth, .monotonic, .monotonic) orelse return;
            }
        }

        fn recordBatch(self: *Self, drained: usize, elapsed_ns: u64) void {
            _ = self.stat_batches.fetchAdd(1, .monotonic);
            _ = self.stat_jobs.fetchAdd(drained, .monotonic);
            _ = self.stat_batch_ns.fetchAdd(elapsed_ns, .monotonic);
            if (drained >= 1 and drained <= FILL_BUCKETS) _ = self.stat_fill[drained - 1].fetchAdd(1, .monotonic);
        }

        fn lockRing(self: *Self) void {
            while (self.ring_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        }

        fn unlockRing(self: *Self) void {
            self.ring_lock.store(false, .release);
        }

        fn lockTables(self: *Self) void {
            while (self.table_lock.swap(true, .acquire)) std.atomic.spinLoopHint();
        }

        fn unlockTables(self: *Self) void {
            self.table_lock.store(false, .release);
        }
    };
}

// --------------------------------------------------------- //

fn nowNanos() u64 {
    var time_spec: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &time_spec);

    return @as(u64, @intCast(time_spec.sec)) * 1_000_000_000 + @as(u64, @intCast(time_spec.nsec));
}

fn waitZero(word: *std.atomic.Value(u32)) void {
    _ = std.os.linux.futex_4arg(&word.raw, .{ .cmd = .WAIT, .private = true }, 0, null);
}

fn wake(word: *std.atomic.Value(u32), count: usize) void {
    _ = std.os.linux.futex_3arg(&word.raw, .{ .cmd = .WAKE, .private = true }, @intCast(count));
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

const testing = std.testing;

test "postgrez: sizeWorkers floors, scales per cpu, caps at the ceiling" {
    // no hint: conservative floor
    try testing.expectEqual(@as(usize, 16), sizeWorkers(64, 0));

    // hint/2 wins while it stays under the per-cpu cap and the ceiling
    try testing.expectEqual(@as(usize, 32), sizeWorkers(64, 64));

    // few cpus cap the fleet below hint/2 (4 cpus -> 32 cap, hint/2 = 128)
    try testing.expectEqual(@as(usize, 32), sizeWorkers(4, 256));

    // many cpus and a large hint still stop at WORKER_CAP
    try testing.expectEqual(@as(usize, 128), sizeWorkers(64, 1024));

    // hint/2 below the floor is lifted to 16
    try testing.expectEqual(@as(usize, 16), sizeWorkers(8, 8));
}

const ProbeJob = struct {
    id: usize,
};

const Probe = struct {
    var ran: std.atomic.Value(u32) = .init(0);
    var saw_connected: std.atomic.Value(u32) = .init(0);

    fn reset() void {
        ran.store(0, .monotonic);
        saw_connected.store(0, .monotonic);
    }

    fn runBatch(batch: *Executor(ProbeJob, 1).Batch, jobs: []const ProbeJob) void {
        if (batch.connected()) _ = saw_connected.fetchAdd(1, .monotonic);

        // no server in this test: statement() must return null, not crash
        if (batch.statement(0, "SELECT 1") != null) _ = saw_connected.fetchAdd(100, .monotonic);

        _ = ran.fetchAdd(@intCast(jobs.len), .monotonic);
    }
};

test "postgrez: executor runs a submitted job with a null batch when no server" {
    Probe.reset();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    // port 1 on loopback: acquire fails fast, run_batch sees a null batch
    var executor = try Executor(ProbeJob, 1).init(testing.allocator, threaded.io(), .{
        .user = "tester",
        .ip = "127.0.0.1",
        .port = 1,
        .retry_max = 0,
        .retry_delay_ms = 1,
    }, .{
        .run_batch = Probe.runBatch,
        .workers = 2,
        .batch_max = 4,
        .stats = true,
    });
    defer executor.deinit();

    try testing.expect(executor.submit(.{ .id = 1 }));

    // wait for the worker to run the batch
    var spins: usize = 0;
    while (Probe.ran.load(.monotonic) == 0) : (spins += 1) {
        if (spins > 5_000_000) return error.WorkerNeverRan;
        std.atomic.spinLoopHint();
    }

    try testing.expectEqual(@as(u32, 1), Probe.ran.load(.monotonic));
    // acquire failed, so the batch was never connected
    try testing.expectEqual(@as(u32, 0), Probe.saw_connected.load(.monotonic));

    const stats = executor.snapshot();
    try testing.expectEqual(@as(u64, 1), stats.batches);
    try testing.expectEqual(@as(u64, 1), stats.jobs);
}

test "postgrez: executor rejects a batch_max wider than the histogram" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    try testing.expectError(error.BatchTooWide, Executor(ProbeJob, 1).init(testing.allocator, threaded.io(), .{
        .user = "tester",
    }, .{
        .run_batch = Probe.runBatch,
        .workers = 1,
        .batch_max = FILL_BUCKETS + 1,
    }));
}

test "postgrez: executor submit sheds when the queue is full" {
    Probe.reset();

    var threaded = std.Io.Threaded.init(testing.allocator, .{});
    defer threaded.deinit();

    // one worker, parked on a dead server acquire, queue depth 2: the third
    // submit with the worker stuck cannot be guaranteed full, so drive the
    // ring directly through submit while the worker is asleep pre-first-job
    var executor = try Executor(ProbeJob, 1).init(testing.allocator, threaded.io(), .{
        .user = "tester",
        .ip = "127.0.0.1",
        .port = 1,
        .retry_max = 0,
        .retry_delay_ms = 1,
    }, .{
        .run_batch = Probe.runBatch,
        .workers = 1,
        .queue_len = 2,
        .batch_max = 1,
    });
    defer executor.deinit();

    // fill the ring by hand under the lock so the worker cannot drain it,
    // proving submit sheds at capacity (a live drain race is covered by the
    // integration suite)
    executor.lockRing();
    executor.count = executor.queue_len;
    executor.unlockRing();

    try testing.expect(!executor.submit(.{ .id = 99 }));

    // restore so deinit's quiescent teardown is clean
    executor.lockRing();
    executor.count = 0;
    executor.unlockRing();
}
