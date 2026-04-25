#pragma once

// Access private/protected members of Hyprland classes.
// Needed for InputMethodRelay::getFocusedTextInput() and similar.
#define private public
#define protected public

#include <hyprland/src/includes.hpp>
#include <hyprland/src/plugins/PluginAPI.hpp>

inline HANDLE PHANDLE = nullptr;
