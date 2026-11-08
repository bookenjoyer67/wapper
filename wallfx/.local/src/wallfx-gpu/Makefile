CC      ?= gcc
CFLAGS  ?= -O2 -Wall -Wextra -Wno-unused-parameter
PKGS    := wayland-client wayland-egl egl glesv2
CFLAGS  += $(shell pkg-config --cflags $(PKGS))
LDLIBS  += $(shell pkg-config --libs $(PKGS)) -lm

XSDG_XML := /usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml

WLR_H := wlr-layer-shell-unstable-v1-client-protocol.h
WLR_C := wlr-layer-shell-unstable-v1-protocol.c
XDG_H := xdg-shell-client-protocol.h
XDG_C := xdg-shell-protocol.c
GEN   := $(WLR_H) $(WLR_C) $(XDG_H) $(XDG_C)
TARGET := wallfx-gpu

all: $(TARGET)

$(WLR_H): wlr-layer-shell-unstable-v1.xml
	wayland-scanner client-header $< $@

$(WLR_C): wlr-layer-shell-unstable-v1.xml
	wayland-scanner private-code $< $@

$(XDG_H): $(XSDG_XML)
	wayland-scanner client-header $< $@

$(XDG_C): $(XSDG_XML)
	wayland-scanner private-code $< $@

$(TARGET): wallfx-gpu.c $(GEN)
	$(CC) $(CFLAGS) -o $@ wallfx-gpu.c $(WLR_C) $(XDG_C) $(LDLIBS)

install: $(TARGET)
	install -Dm755 $(TARGET) $(HOME)/.local/bin/$(TARGET)

clean:
	rm -f $(TARGET) $(GEN)

.PHONY: all install clean
