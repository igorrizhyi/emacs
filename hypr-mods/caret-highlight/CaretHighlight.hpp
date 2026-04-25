#pragma once

#include "../globals.hpp"

#include <hyprland/src/SharedDefs.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/managers/input/InputMethodRelay.hpp>
#include <hyprland/src/managers/input/TextInput.hpp>

// Forward declarations
class CCaretHighlight {
  public:
    CCaretHighlight();
    ~CCaretHighlight();

  private:
    void onRenderStage(eRenderStage stage);

    // Listener handle for the render stage signal
    CHyprSignalListener m_renderStageListener;
};

inline std::unique_ptr<CCaretHighlight> g_pCaretHighlight;
