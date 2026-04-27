#include "CaretHighlight.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/View.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/Renderer.hpp>

// ─── Config value accessors ──────────────────────────────────────────────────

static Hyprlang::INT getEnabled() {
    static auto* const p = HyprlandAPI::getConfigValue(
        PHANDLE, "plugin:hypr-mods:caret_highlight:enabled");
    if (!p) return 0;
    return std::any_cast<Hyprlang::INT>(p->getValue());
}

static Hyprlang::INT getColor() {
    static auto* const p = HyprlandAPI::getConfigValue(
        PHANDLE, "plugin:hypr-mods:caret_highlight:color");
    if (!p) return 0;
    return std::any_cast<Hyprlang::INT>(p->getValue());
}

static Hyprlang::INT getSize() {
    static auto* const p = HyprlandAPI::getConfigValue(
        PHANDLE, "plugin:hypr-mods:caret_highlight:size");
    if (!p) return 2;
    return std::any_cast<Hyprlang::INT>(p->getValue());
}

// ─── CCaretHighlight ─────────────────────────────────────────────────────────

CCaretHighlight::CCaretHighlight() {
    m_renderStageListener = Event::bus()->m_events.render.stage.listen(
        [this](eRenderStage stage) { onRenderStage(stage); });
}

CCaretHighlight::~CCaretHighlight() {
    // m_renderStageListener destructor disconnects automatically
}

void CCaretHighlight::onRenderStage(eRenderStage stage) {
    // Only draw after all windows are composited, before top/overlay layers
    if (stage != RENDER_POST_WINDOWS)
        return;

    // ── 1. Check if the feature is enabled ───────────────────────────────────
    if (getEnabled() == 0)
        return;

    // ── 2. Get the focused text input ────────────────────────────────────────
    // Uses the CTextInput wrapper (not raw CTextInputV3), exactly as
    // InputMethodPopup.cpp does it.
    CTextInput* pFocused = g_pInputManager->m_relay.getFocusedTextInput();
    if (!pFocused)
        return;

    if (!pFocused->isEnabled())
        return;

    if (!pFocused->hasCursorRectangle())
        return;

    // ── 3. Get cursor box (surface-local coordinates) ─────────────────────────
    const CBox cursorBoxLocal = pFocused->cursorBox();

    // ── 4. Get the focused surface and its global position ────────────────────
    SP<CWLSurfaceResource> pSurface = pFocused->focusedSurface();
    if (!pSurface)
        return;

    auto pCWLSurface = Desktop::View::CWLSurface::fromResource(pSurface);
    if (!pCWLSurface)
        return;

    const std::optional<CBox> surfaceBoxGlobal = pCWLSurface->getSurfaceBoxGlobal();
    if (!surfaceBoxGlobal.has_value())
        return;

    // ── 5. Compute global caret box ───────────────────────────────────────────
    // Translate the surface-local cursor box by the surface's global origin.
    const int padding = static_cast<int>(getSize());

    CBox caretBoxGlobal(
        surfaceBoxGlobal->x + cursorBoxLocal.x - padding,
        surfaceBoxGlobal->y + cursorBoxLocal.y - padding,
        (cursorBoxLocal.w > 0 ? cursorBoxLocal.w : 2) + padding * 2,
        (cursorBoxLocal.h > 0 ? cursorBoxLocal.h : 16) + padding * 2);

    // ── 6. Map to current monitor ─────────────────────────────────────────────
    // The render stage callback fires once per monitor. We only draw when the
    // caret falls on the monitor currently being composited.
    const auto pMonitor = g_pHyprOpenGL->m_renderData.pMonitor;
    if (!pMonitor)
        return;

    const CBox monitorBox(pMonitor->m_position.x, pMonitor->m_position.y,
                          pMonitor->m_size.x, pMonitor->m_size.y);

    if (!caretBoxGlobal.overlaps(monitorBox))
        return;

    // Convert global → monitor-local coordinates (unscaled logical pixels)
    CBox localBox = caretBoxGlobal;
    localBox.x   -= pMonitor->m_position.x;
    localBox.y   -= pMonitor->m_position.y;

    // Scale to physical pixels for rendering
    localBox.scale(pMonitor->m_scale);

    // ── 7. Draw the highlight rectangle ──────────────────────────────────────
    const uint32_t colorRaw = static_cast<uint32_t>(getColor());
    // Config stores color as 0xRRGGBBAA (Hyprlang RGBA convention)
    const CHyprColor highlightColor{colorRaw};

    g_pHyprOpenGL->renderRect(localBox, highlightColor, CHyprOpenGLImpl::SRectRenderData{.round = 2});
}
