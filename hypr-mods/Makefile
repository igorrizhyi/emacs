PLUGIN_NAME := hypr-mods

# Collect all .cpp files recursively
SOURCE_FILES := $(shell find . -name '*.cpp' -not -path './.git/*')
OBJ_FILES    := $(SOURCE_FILES:.cpp=.o)

# Hyprland provides a pkg-config entry when hyprland-devel (or equivalent) is installed
HYPRLAND_FLAGS := $(shell pkg-config --cflags hyprland 2>/dev/null)

INCLUDES := $(HYPRLAND_FLAGS)

CXXFLAGS := \
    -std=c++26 \
    -fPIC \
    -O2 \
    -DWLR_USE_UNSTABLE \
    $(INCLUDES)

LDFLAGS  := -shared -fPIC

CXX ?= g++

all: $(PLUGIN_NAME).so

$(PLUGIN_NAME).so: $(OBJ_FILES)
	$(CXX) $(LDFLAGS) -o $@ $^

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	find . -name '*.o' -delete
	rm -f $(PLUGIN_NAME).so

.PHONY: all clean
