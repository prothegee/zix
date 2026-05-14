//! Behaviour tests: zix.Http.Content.typeFromExtension and fromExtension contracts.
//! Verifies the mapping rules callers rely on: extension groups, case-insensitivity,
//! alias pairs producing identical MIME strings, and the MIME string values themselves.

const std = @import("std");
const zix = @import("zix");

const Content = zix.Http.Content;

// --------------------------------------------------------- //

test "zix behaviour: typeFromExtension, text group" {
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_HTML, Content.typeFromExtension("html"));
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_HTML, Content.typeFromExtension("htm"));
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_CSS, Content.typeFromExtension("css"));
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_PLAIN, Content.typeFromExtension("txt"));
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_CSV, Content.typeFromExtension("csv"));
}

test "zix behaviour: typeFromExtension, application group" {
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_JSON, Content.typeFromExtension("json"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_JSON, Content.typeFromExtension("map"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_JAVASCRIPT, Content.typeFromExtension("js"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_JAVASCRIPT, Content.typeFromExtension("min.js"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_XML, Content.typeFromExtension("xml"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_PDF, Content.typeFromExtension("pdf"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_WASM, Content.typeFromExtension("wasm"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_ZIP, Content.typeFromExtension("zip"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_GZIP, Content.typeFromExtension("gz"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_TAR, Content.typeFromExtension("tar"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_7Z_COMPRESSED, Content.typeFromExtension("7z"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_VND_RAR, Content.typeFromExtension("rar"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_RTF, Content.typeFromExtension("rtf"));
}

test "zix behaviour: typeFromExtension, image group" {
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_PNG, Content.typeFromExtension("png"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_JPEG, Content.typeFromExtension("jpg"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_JPEG, Content.typeFromExtension("jpeg"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_GIF, Content.typeFromExtension("gif"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_SVG_XML, Content.typeFromExtension("svg"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_WEBP, Content.typeFromExtension("webp"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_X_ICON, Content.typeFromExtension("ico"));
}

test "zix behaviour: typeFromExtension, audio group" {
    try std.testing.expectEqual(zix.Http.ContentType.AUDIO_MPEG, Content.typeFromExtension("mp3"));
    try std.testing.expectEqual(zix.Http.ContentType.AUDIO_WAV, Content.typeFromExtension("wav"));
    try std.testing.expectEqual(zix.Http.ContentType.AUDIO_FLAC, Content.typeFromExtension("flac"));
    try std.testing.expectEqual(zix.Http.ContentType.AUDIO_MIDI, Content.typeFromExtension("mid"));
    try std.testing.expectEqual(zix.Http.ContentType.AUDIO_MIDI, Content.typeFromExtension("midi"));
}

test "zix behaviour: typeFromExtension, video group" {
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_MP4, Content.typeFromExtension("mp4"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_WEBM, Content.typeFromExtension("webm"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_OGG, Content.typeFromExtension("ogg"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_MPEG, Content.typeFromExtension("mpeg"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_AVI, Content.typeFromExtension("avi"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_MOV, Content.typeFromExtension("mov"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_WMV, Content.typeFromExtension("wmv"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_FLV, Content.typeFromExtension("flv"));
    try std.testing.expectEqual(zix.Http.ContentType.VIDEO_MKV, Content.typeFromExtension("mkv"));
}

test "zix behaviour: typeFromExtension, font group" {
    try std.testing.expectEqual(zix.Http.ContentType.FONT_TTF, Content.typeFromExtension("ttf"));
    try std.testing.expectEqual(zix.Http.ContentType.FONT_OTF, Content.typeFromExtension("otf"));
    try std.testing.expectEqual(zix.Http.ContentType.FONT_WOFF, Content.typeFromExtension("woff"));
    try std.testing.expectEqual(zix.Http.ContentType.FONT_WOFF2, Content.typeFromExtension("woff2"));
}

// --------------------------------------------------------- //

test "zix behaviour: typeFromExtension, matching is case-insensitive" {
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_HTML, Content.typeFromExtension("HTML"));
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_HTML, Content.typeFromExtension("HTM"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_PNG, Content.typeFromExtension("PNG"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_JAVASCRIPT, Content.typeFromExtension("JS"));
    try std.testing.expectEqual(zix.Http.ContentType.APPLICATION_JSON, Content.typeFromExtension("JSON"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_JPEG, Content.typeFromExtension("JPG"));
    try std.testing.expectEqual(zix.Http.ContentType.IMAGE_JPEG, Content.typeFromExtension("JPEG"));
    try std.testing.expectEqual(zix.Http.ContentType.TEXT_CSS, Content.typeFromExtension("CSS"));
    try std.testing.expectEqual(zix.Http.ContentType.FONT_WOFF2, Content.typeFromExtension("WOFF2"));
}

// --------------------------------------------------------- //

test "zix behaviour: fromExtension, returns correct MIME string" {
    try std.testing.expectEqualStrings("text/html", Content.fromExtension("html"));
    try std.testing.expectEqualStrings("application/json", Content.fromExtension("json"));
    try std.testing.expectEqualStrings("image/png", Content.fromExtension("png"));
    try std.testing.expectEqualStrings("text/css", Content.fromExtension("css"));
    try std.testing.expectEqualStrings("application/javascript", Content.fromExtension("js"));
    try std.testing.expectEqualStrings("font/woff2", Content.fromExtension("woff2"));
    try std.testing.expectEqualStrings("video/mp4", Content.fromExtension("mp4"));
    try std.testing.expectEqualStrings("audio/mpeg", Content.fromExtension("mp3"));
    try std.testing.expectEqualStrings("application/wasm", Content.fromExtension("wasm"));
    try std.testing.expectEqualStrings("image/x-icon", Content.fromExtension("ico"));
}

test "zix behaviour: fromExtension, alias pairs produce identical MIME strings" {
    try std.testing.expectEqualStrings(Content.fromExtension("jpg"), Content.fromExtension("jpeg"));
    try std.testing.expectEqualStrings(Content.fromExtension("mid"), Content.fromExtension("midi"));
    try std.testing.expectEqualStrings(Content.fromExtension("html"), Content.fromExtension("htm"));
    try std.testing.expectEqualStrings(Content.fromExtension("js"), Content.fromExtension("min.js"));
    try std.testing.expectEqualStrings(Content.fromExtension("json"), Content.fromExtension("map"));
}
