// zix http content

const std = @import("std");

pub const Type = enum(u8) {
    const Self = @This();

    // --------------------------------------------------------- //

    NA,

    TEXT_PLAIN,
    TEXT_HTML,
    TEXT_CSS, // css, min.css
    TEXT_CSV,

    AUDIO_MPEG,
    AUDIO_WAV,
    AUDIO_FLAC,
    AUDIO_MIDI, // mid, midi

    APPLICATION_JAVASCRIPT, // js, min.js
    APPLICATION_JSON, // json, map
    APPLICATION_PDF,
    APPLICATION_XML,
    APPLICATION_RTF,
    APPLICATION_ZIP,
    APPLICATION_GZIP,
    APPLICATION_TAR,
    APPLICATION_7Z_COMPRESSED,
    APPLICATION_VND_RAR,
    APPLICATION_LD_JSON,
    APPLICATION_RDF_XML,
    APPLICATION_RSS_XML,
    APPLICATION_ATOM_XML,
    APPLICATION_GRAPHQL, // graphql and graphqls
    APPLICATION_WASM,
    APPLICATION_MANIFEST_JSON, // manifest, webmanifest
    APPLICATION_OCTET_STREAM,

    IMAGE_PNG,
    IMAGE_JPEG, // jpeg, jpg
    IMAGE_GIF,
    IMAGE_SVG_XML,
    IMAGE_WEBP,
    IMAGE_X_ICON,

    VIDEO_MP4,
    VIDEO_WEBM,
    VIDEO_OGG,
    VIDEO_MPEG,
    VIDEO_AVI,
    VIDEO_MOV,
    VIDEO_WMV,
    VIDEO_FLV,
    VIDEO_MKV,

    FONT_TTF,
    FONT_OTF,
    FONT_WOFF,
    FONT_WOFF2,

    // --------------------------------------------------------- //

    /// Brief:
    /// Get self object string from enum
    ///
    /// Note:
    /// - exhaustive
    ///
    /// Param:
    /// self - zix.Tcp.Http.Content.Type
    ///
    /// Return:
    /// []const u8
    fn toString(self: Type) []const u8 {
        return switch (self) {
            .NA => "n/a",

            .TEXT_PLAIN => "text/plain",
            .TEXT_HTML => "text/html",
            .TEXT_CSS => "text/css",
            .TEXT_CSV => "text/csv",

            .AUDIO_MPEG => "audio/mpeg",
            .AUDIO_WAV => "audio/wav",
            .AUDIO_FLAC => "audio/flac",
            .AUDIO_MIDI => "audio/midi",

            .APPLICATION_JAVASCRIPT => "application/javascript",
            .APPLICATION_JSON => "application/json",
            .APPLICATION_PDF => "application/pdf",
            .APPLICATION_XML => "application/xml",
            .APPLICATION_RTF => "application/rtf",
            .APPLICATION_ZIP => "application/zip",
            .APPLICATION_GZIP => "application/gzip",
            .APPLICATION_TAR => "application/x-tar",
            .APPLICATION_7Z_COMPRESSED => "application/x-7z-compressed",
            .APPLICATION_VND_RAR => "application/vnd.rar",
            .APPLICATION_LD_JSON => "application/jsonld",
            .APPLICATION_RDF_XML => "application/rdf+xml",
            .APPLICATION_RSS_XML => "application/rss+xml",
            .APPLICATION_ATOM_XML => "application/atom+xml",
            .APPLICATION_GRAPHQL => "application/graphql",
            .APPLICATION_WASM => "application/wasm",
            .APPLICATION_MANIFEST_JSON => "application/manifest+json",
            .APPLICATION_OCTET_STREAM => "application/octet-stream",

            .IMAGE_PNG => "image/png",
            .IMAGE_JPEG => "image/jpeg",
            .IMAGE_GIF => "image/gif",
            .IMAGE_SVG_XML => "image/svg+xml",
            .IMAGE_WEBP => "image/webp",
            .IMAGE_X_ICON => "image/x-icon",

            .VIDEO_MP4 => "video/mp4",
            .VIDEO_WEBM => "video/webm",
            .VIDEO_OGG => "video/ogg",
            .VIDEO_MPEG => "video/mpeg",
            .VIDEO_AVI => "video/x-msvideo",
            .VIDEO_MOV => "video/quicktime",
            .VIDEO_WMV => "video/x-ms-wmv",
            .VIDEO_FLV => "video/x-flv",
            .VIDEO_MKV => "video/x-matroska",

            .FONT_TTF => "font/ttf",
            .FONT_OTF => "font/otf",
            .FONT_WOFF => "font/woff",
            .FONT_WOFF2 => "font/woff2",
        };
    }
    /// Brief:
    /// Get self object as a string
    ///
    /// Return:
    /// []const u8
    pub fn asString(self: Self) []const u8 {
        return Self.toString(self);
    }
};

/// Brief:
/// Get enum from string
///
/// Note:
/// - If not match, it will return NA
///
/// Params:
/// type_string - []const u8 (insensitive, forced to lowercase)
///
/// Return:
/// zix.Tcp.Http.Content.Type
pub fn enumFromString(type_string: []const u8) Type {
    var data: [32]u8 = undefined;
    const mod = std.ascii.lowerString(&data, type_string);

    if (std.mem.eql(u8, mod, "n/a")) {
        return Type.NA;
    }

    if (std.mem.eql(u8, mod, "text/plain")) {
        return Type.TEXT_PLAIN;
    }
    if (std.mem.eql(u8, mod, "text/html")) {
        return Type.TEXT_HTML;
    }
    if (std.mem.eql(u8, mod, "text/css")) {
        return Type.TEXT_CSS;
    }
    if (std.mem.eql(u8, mod, "text/csv")) {
        return Type.TEXT_CSV;
    }

    if (std.mem.eql(u8, mod, "audio/mpeg")) {
        return Type.AUDIO_MPEG;
    }
    if (std.mem.eql(u8, mod, "audio/wav")) {
        return Type.AUDIO_WAV;
    }
    if (std.mem.eql(u8, mod, "audio/flac")) {
        return Type.AUDIO_FLAC;
    }
    if (std.mem.eql(u8, mod, "audio/midi")) {
        return Type.AUDIO_MIDI;
    }

    if (std.mem.eql(u8, mod, "application/javascript")) {
        return Type.APPLICATION_JAVASCRIPT;
    }
    if (std.mem.eql(u8, mod, "application/json")) {
        return Type.APPLICATION_JSON;
    }
    if (std.mem.eql(u8, mod, "application/pdf")) {
        return Type.APPLICATION_PDF;
    }
    if (std.mem.eql(u8, mod, "application/xml")) {
        return Type.APPLICATION_XML;
    }
    if (std.mem.eql(u8, mod, "application/rtf")) {
        return Type.APPLICATION_RTF;
    }
    if (std.mem.eql(u8, mod, "application/zip")) {
        return Type.APPLICATION_ZIP;
    }
    if (std.mem.eql(u8, mod, "application/gzip")) {
        return Type.APPLICATION_GZIP;
    }
    if (std.mem.eql(u8, mod, "application/x-tar")) {
        return Type.APPLICATION_TAR;
    }
    if (std.mem.eql(u8, mod, "application/x-7z-compressed")) {
        return Type.APPLICATION_7Z_COMPRESSED;
    }
    if (std.mem.eql(u8, mod, "application/vnd.rar")) {
        return Type.APPLICATION_VND_RAR;
    }
    if (std.mem.eql(u8, mod, "application/jsonld")) {
        return Type.APPLICATION_LD_JSON;
    }
    if (std.mem.eql(u8, mod, "application/rdf+xml")) {
        return Type.APPLICATION_RDF_XML;
    }
    if (std.mem.eql(u8, mod, "application/rss+xml")) {
        return Type.APPLICATION_RSS_XML;
    }
    if (std.mem.eql(u8, mod, "application/atom+xml")) {
        return Type.APPLICATION_ATOM_XML;
    }
    if (std.mem.eql(u8, mod, "application/graphql")) {
        return Type.APPLICATION_GRAPHQL;
    }
    if (std.mem.eql(u8, mod, "application/wasm")) {
        return Type.APPLICATION_WASM;
    }
    if (std.mem.eql(u8, mod, "application/manifest+json")) {
        return Type.APPLICATION_MANIFEST_JSON;
    }
    if (std.mem.eql(u8, mod, "application/octet-stream")) {
        return Type.APPLICATION_OCTET_STREAM;
    }

    if (std.mem.eql(u8, mod, "image/png")) {
        return Type.IMAGE_PNG;
    }
    if (std.mem.eql(u8, mod, "image/jpeg")) {
        return Type.IMAGE_JPEG;
    }
    if (std.mem.eql(u8, mod, "image/gif")) {
        return Type.IMAGE_GIF;
    }
    if (std.mem.eql(u8, mod, "image/svg+xml")) {
        return Type.IMAGE_SVG_XML;
    }
    if (std.mem.eql(u8, mod, "image/webp")) {
        return Type.IMAGE_WEBP;
    }
    if (std.mem.eql(u8, mod, "image/x-icon")) {
        return Type.IMAGE_X_ICON;
    }

    if (std.mem.eql(u8, mod, "video/mp4")) {
        return Type.VIDEO_MP4;
    }
    if (std.mem.eql(u8, mod, "video/webm")) {
        return Type.VIDEO_WEBM;
    }
    if (std.mem.eql(u8, mod, "video/ogg")) {
        return Type.VIDEO_OGG;
    }
    if (std.mem.eql(u8, mod, "video/mpeg")) {
        return Type.VIDEO_MPEG;
    }
    if (std.mem.eql(u8, mod, "video/x-msvideo")) {
        return Type.VIDEO_AVI;
    }
    if (std.mem.eql(u8, mod, "video/quicktime")) {
        return Type.VIDEO_MOV;
    }
    if (std.mem.eql(u8, mod, "video/x-ms-wmv")) {
        return Type.VIDEO_WMV;
    }
    if (std.mem.eql(u8, mod, "video/x-flv")) {
        return Type.VIDEO_FLV;
    }
    if (std.mem.eql(u8, mod, "video/x-matroska")) {
        return Type.VIDEO_MKV;
    }

    if (std.mem.eql(u8, mod, "font/ttf")) {
        return Type.FONT_TTF;
    }
    if (std.mem.eql(u8, mod, "font/otf")) {
        return Type.FONT_OTF;
    }
    if (std.mem.eql(u8, mod, "font/woff")) {
        return Type.FONT_WOFF;
    }
    if (std.mem.eql(u8, mod, "font/woff2")) {
        return Type.FONT_WOFF2;
    }

    return Type.NA;
}

/// Brief:
/// Get string from enum
///
/// Note:
/// - Exhaustive
/// - Seperated by it's enum
///
/// Param:
/// method_enum - zix.Tcp.Http.Content.Type
///
/// Return:
/// []const u8
pub fn stringFromEnum(content_enum: Type) []const u8 {
    return switch (content_enum) {
        .NA => "n/a",

        .TEXT_PLAIN => "text/plain",
        .TEXT_HTML => "text/html",
        .TEXT_CSS => "text/css",
        .TEXT_CSV => "text/csv",

        .AUDIO_MPEG => "audio/mpeg",
        .AUDIO_WAV => "audio/wav",
        .AUDIO_FLAC => "audio/flac",
        .AUDIO_MIDI => "audio/midi",

        .APPLICATION_JAVASCRIPT => "application/javascript",
        .APPLICATION_JSON => "application/json",
        .APPLICATION_PDF => "application/pdf",
        .APPLICATION_XML => "application/xml",
        .APPLICATION_RTF => "application/rtf",
        .APPLICATION_ZIP => "application/zip",
        .APPLICATION_GZIP => "application/gzip",
        .APPLICATION_TAR => "application/x-tar",
        .APPLICATION_7Z_COMPRESSED => "application/x-7z-compressed",
        .APPLICATION_VND_RAR => "application/vnd.rar",
        .APPLICATION_LD_JSON => "application/jsonld",
        .APPLICATION_RDF_XML => "application/rdf+xml",
        .APPLICATION_RSS_XML => "application/rss+xml",
        .APPLICATION_ATOM_XML => "application/atom+xml",
        .APPLICATION_GRAPHQL => "application/graphql",
        .APPLICATION_WASM => "application/wasm",
        .APPLICATION_MANIFEST_JSON => "application/manifest+json",
        .APPLICATION_OCTET_STREAM => "application/octet-stream",

        .IMAGE_PNG => "image/png",
        .IMAGE_JPEG => "image/jpeg",
        .IMAGE_GIF => "image/gif",
        .IMAGE_SVG_XML => "image/svg+xml",
        .IMAGE_WEBP => "image/webp",
        .IMAGE_X_ICON => "image/x-icon",

        .VIDEO_MP4 => "video/mp4",
        .VIDEO_WEBM => "video/webm",
        .VIDEO_OGG => "video/ogg",
        .VIDEO_MPEG => "video/mpeg",
        .VIDEO_AVI => "video/x-msvideo",
        .VIDEO_MOV => "video/quicktime",
        .VIDEO_WMV => "video/x-ms-wmv",
        .VIDEO_FLV => "video/x-flv",
        .VIDEO_MKV => "video/x-matroska",

        .FONT_TTF => "font/ttf",
        .FONT_OTF => "font/otf",
        .FONT_WOFF => "font/woff",
        .FONT_WOFF2 => "font/woff2",
    };
}

/// Brief:
/// Get Content.Type enum from a file extension
///
/// Note:
/// - Case-insensitive
/// - Returns .APPLICATION_OCTET_STREAM for unknown extensions
///
/// Param:
/// ext - []const u8 (without leading dot, e.g. "html", "png")
///
/// Return:
/// Type
pub fn typeFromExtension(ext: []const u8) Type {
    if (std.ascii.eqlIgnoreCase(ext, "html") or std.ascii.eqlIgnoreCase(ext, "htm")) return .TEXT_HTML;
    if (std.ascii.eqlIgnoreCase(ext, "css")) return .TEXT_CSS;
    if (std.ascii.eqlIgnoreCase(ext, "js") or std.ascii.eqlIgnoreCase(ext, "min.js")) return .APPLICATION_JAVASCRIPT;
    if (std.ascii.eqlIgnoreCase(ext, "json") or std.ascii.eqlIgnoreCase(ext, "map")) return .APPLICATION_JSON;
    if (std.ascii.eqlIgnoreCase(ext, "txt")) return .TEXT_PLAIN;
    if (std.ascii.eqlIgnoreCase(ext, "csv")) return .TEXT_CSV;
    if (std.ascii.eqlIgnoreCase(ext, "xml")) return .APPLICATION_XML;
    if (std.ascii.eqlIgnoreCase(ext, "rtf")) return .APPLICATION_RTF;
    if (std.ascii.eqlIgnoreCase(ext, "pdf")) return .APPLICATION_PDF;
    if (std.ascii.eqlIgnoreCase(ext, "wasm")) return .APPLICATION_WASM;
    if (std.ascii.eqlIgnoreCase(ext, "zip")) return .APPLICATION_ZIP;
    if (std.ascii.eqlIgnoreCase(ext, "gz")) return .APPLICATION_GZIP;
    if (std.ascii.eqlIgnoreCase(ext, "tar")) return .APPLICATION_TAR;
    if (std.ascii.eqlIgnoreCase(ext, "7z")) return .APPLICATION_7Z_COMPRESSED;
    if (std.ascii.eqlIgnoreCase(ext, "rar")) return .APPLICATION_VND_RAR;
    if (std.ascii.eqlIgnoreCase(ext, "png")) return .IMAGE_PNG;
    if (std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg")) return .IMAGE_JPEG;
    if (std.ascii.eqlIgnoreCase(ext, "gif")) return .IMAGE_GIF;
    if (std.ascii.eqlIgnoreCase(ext, "svg")) return .IMAGE_SVG_XML;
    if (std.ascii.eqlIgnoreCase(ext, "webp")) return .IMAGE_WEBP;
    if (std.ascii.eqlIgnoreCase(ext, "ico")) return .IMAGE_X_ICON;
    if (std.ascii.eqlIgnoreCase(ext, "mp4")) return .VIDEO_MP4;
    if (std.ascii.eqlIgnoreCase(ext, "webm")) return .VIDEO_WEBM;
    if (std.ascii.eqlIgnoreCase(ext, "ogg")) return .VIDEO_OGG;
    if (std.ascii.eqlIgnoreCase(ext, "mpeg")) return .VIDEO_MPEG;
    if (std.ascii.eqlIgnoreCase(ext, "avi")) return .VIDEO_AVI;
    if (std.ascii.eqlIgnoreCase(ext, "mov")) return .VIDEO_MOV;
    if (std.ascii.eqlIgnoreCase(ext, "wmv")) return .VIDEO_WMV;
    if (std.ascii.eqlIgnoreCase(ext, "flv")) return .VIDEO_FLV;
    if (std.ascii.eqlIgnoreCase(ext, "mkv")) return .VIDEO_MKV;
    if (std.ascii.eqlIgnoreCase(ext, "mp3")) return .AUDIO_MPEG;
    if (std.ascii.eqlIgnoreCase(ext, "wav")) return .AUDIO_WAV;
    if (std.ascii.eqlIgnoreCase(ext, "flac")) return .AUDIO_FLAC;
    if (std.ascii.eqlIgnoreCase(ext, "mid") or std.ascii.eqlIgnoreCase(ext, "midi")) return .AUDIO_MIDI;
    if (std.ascii.eqlIgnoreCase(ext, "woff")) return .FONT_WOFF;
    if (std.ascii.eqlIgnoreCase(ext, "woff2")) return .FONT_WOFF2;
    if (std.ascii.eqlIgnoreCase(ext, "ttf")) return .FONT_TTF;
    if (std.ascii.eqlIgnoreCase(ext, "otf")) return .FONT_OTF;
    return .APPLICATION_OCTET_STREAM;
}

/// Brief:
/// Get MIME type string from a file extension
///
/// Note:
/// - Case-insensitive
/// - Returns "application/octet-stream" for unknown extensions
/// - Convenience wrapper around typeFromExtension().asString()
///
/// Param:
/// ext - []const u8 (without leading dot, e.g. "html", "png")
///
/// Return:
/// []const u8
pub fn fromExtension(ext: []const u8) []const u8 {
    return typeFromExtension(ext).asString();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: tcp http content fn/s" {
    try std.testing.expect(true);

    const es = [_]Type{
        Type.NA,

        Type.TEXT_HTML,
        Type.TEXT_CSS, // css, min.css
        Type.TEXT_CSV,

        Type.AUDIO_MPEG,
        Type.AUDIO_WAV,
        Type.AUDIO_FLAC,
        Type.AUDIO_MIDI, // mid, midi

        Type.APPLICATION_JAVASCRIPT, // js, min.js
        Type.APPLICATION_JSON, // json, map
        Type.APPLICATION_PDF,
        Type.APPLICATION_XML,
        Type.APPLICATION_RTF,
        Type.APPLICATION_ZIP,
        Type.APPLICATION_GZIP,
        Type.APPLICATION_TAR,
        Type.APPLICATION_7Z_COMPRESSED,
        Type.APPLICATION_VND_RAR,
        Type.APPLICATION_LD_JSON,
        Type.APPLICATION_RDF_XML,
        Type.APPLICATION_RSS_XML,
        Type.APPLICATION_ATOM_XML,
        Type.APPLICATION_GRAPHQL, // graphql and graphqls
        Type.APPLICATION_WASM,
        Type.APPLICATION_MANIFEST_JSON, // manifest, webmanifest
        Type.APPLICATION_OCTET_STREAM,

        Type.IMAGE_PNG,
        Type.IMAGE_JPEG, // jpeg, jpg
        Type.IMAGE_GIF,
        Type.IMAGE_SVG_XML,
        Type.IMAGE_WEBP,
        Type.IMAGE_X_ICON,

        Type.VIDEO_MP4,
        Type.VIDEO_WEBM,
        Type.VIDEO_OGG,
        Type.VIDEO_MPEG,
        Type.VIDEO_AVI,
        Type.VIDEO_MOV,
        Type.VIDEO_WMV,
        Type.VIDEO_FLV,
        Type.VIDEO_MKV,

        Type.FONT_TTF,
        Type.FONT_OTF,
        Type.FONT_WOFF,
        Type.FONT_WOFF2,
    };

    for (es) |e| {
        const e_str = stringFromEnum(e);

        try std.testing.expect(std.mem.eql(u8, e_str, e.asString()));

        const expected1 = enumFromString(e_str);
        try std.testing.expect(expected1 == e);

        const expected2 = stringFromEnum(e);
        try std.testing.expect(std.mem.eql(u8, e_str, expected2));
    }
}
