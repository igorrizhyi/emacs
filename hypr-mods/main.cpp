#include "globals.hpp"
#include "caret-highlight/CaretHighlight.hpp"

#include <hyprland/src/plugins/PluginAPI.hpp>

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    // ── ABI version check ──────────────────────────────────────────────────────
    // Abort early if the plugin was compiled against a different Hyprland ABI.
    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();
    if (HASH != CLIENT_HASH) {
        HyprlandAPI::addNotification(
            PHANDLE,
            "[hypr-mods] ABI mismatch — recompile the plugin for this Hyprland build.",
            CHyprColor{1.0f, 0.2f, 0.2f, 1.0f},
            /*timeout_ms=*/5000);
        throw std::runtime_error("[hypr-mods] ABI mismatch");
    }

    // ── Config values ─────────────────────────────────────────────────────────
    HyprlandAPI::addConfigValue(
        PHANDLE, "plugin:hypr-mods:caret_highlight:enabled", Hyprlang::INT{1});

    // Default color: bright yellow, fully opaque (0xFFFF00FF in 0xRRGGBBAA)
    HyprlandAPI::addConfigValue(
        PHANDLE, "plugin:hypr-mods:caret_highlight:color",
        Hyprlang::INT{static_cast<int64_t>(0xFFFF00FFu)});

    // Extra padding (pixels) added around the raw cursor box
    HyprlandAPI::addConfigValue(
        PHANDLE, "plugin:hypr-mods:caret_highlight:size", Hyprlang::INT{2});

    // ── Initialise modules ────────────────────────────────────────────────────
    g_pCaretHighlight = std::make_unique<CCaretHighlight>();

    HyprlandAPI::addNotification(
        PHANDLE, "[hypr-mods] Loaded — caret highlight active.",
        CHyprColor{0.2f, 1.0f, 0.2f, 1.0f},
        /*timeout_ms=*/3000);

    return {"hypr-mods",
            "Hyprland tweaks: caret highlighter and more.",
            "igorrizhyi",
            "0.1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_pCaretHighlight.reset();
}
