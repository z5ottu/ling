LING_VER := 0.5.0
OTP_VER := 17

ifeq ($(ERL_BIN),)
ERL := erl
ERLC := erlc
ESCRIPT := escript
else
ERL := $(ERL_BIN)/erl
ERLC := $(ERL_BIN)/erlc
ESCRIPT := $(ERL_BIN)/escript
endif

ifneq (true,$(shell $(ERL) -noshell -eval "io:format(list_to_integer(erlang:system_info(otp_release)) == $(OTP_VER)),halt(0)."))
$(error Erlang/OTP $(OTP_VER) required)
endif

-include .config
rebuild =
ifeq ($(ARCH),)
_ARCH ?= xen
ARCH  := $(_ARCH)
endif
ifneq ($(ARCH),$(_ARCH))
	rebuild = yes
endif
ifeq ($(CONF),)
_CONF ?= opt
CONF  := $(_CONF)
endif
ifneq ($(CONF),$(_CONF))
	rebuild = yes
endif
ifdef rebuild
$(shell printf "_ARCH=$(ARCH)\n_CONF=$(CONF)" > .config )
endif

ifeq ($(shell uname -s),Darwin)
LING_DARWIN := 1
else
LING_LINUX := 1
endif

ifeq ($(ARCH),xen)
LING_XEN=1
else ifeq ($(ARCH),posix)
LING_POSIX=1
else
$(error Unknown ARCH)
endif

ifeq ($(CONF),dbg)
LING_DEBUG=1
else ifeq ($(CONF),lto)
LING_LTO=1
else ifeq ($(CONF),opt)
# do nothing
else
$(error Unknown CONF)
endif


default: railing/railing

test: default
	cd test && ../railing/railing image -ipriv

ifdef LING_POSIX
play: test
	./test/test.img -home /test -s test play
else
play: test
	@echo Tests available on POSIX builds only
endif

install: railing/railing
	install railing/railing /usr/bin

## TEST
TEST_ERL := $(wildcard test/src/*.erl)
TEST_BEAM := $(TEST_ERL:test/src/%.erl=test/ebin/%.beam)

test/ebin/%.beam: test/src/%.erl
	$(ERLC) -o test/ebin $<

## BC
BC_SAMPLE_ERL := $(wildcard bc/sample/*.erl)
BC_SAMPLE_BEAM := $(BC_SAMPLE_ERL:%.erl=%.beam)

$(BC_SAMPLE_BEAM): %.beam: %.erl
	$(ERLC) -o bc/sample $<

BC_BEAM := \
	bc/bfd_objcopy.beam \
	bc/ling_disasm.beam \
	bc/erltl.beam \
	bc/ling_code.beam \
	bc/ling_iops.beam \
	bc/ling_lib.beam

$(BC_BEAM): %.beam: %.erl
	$(ERLC) -o bc $<

## TODO: use erlc dependency generation instead
bc/ling_code.beam: bc/ling_bifs.beam
bc/ling_bifs.beam: bc/ling_bifs.erl
	$(ERLC) -o $(shell dirname $@) $<

bc/gentab/iops_tab.erl: bc/scripts/iops.tab bc/scripts/iops_tab_erl.et $(BC_BEAM) 
	$(ESCRIPT) bc/scripts/iops_gen bc/scripts/iops.tab bc/scripts/iops_tab_erl.et $@

bc/gentab/%.beam: bc/gentab/%.erl
	$(ERLC) -o bc/gentab $<

bc/scripts/iopvars.tab: bc/scripts/beam.src bc/scripts/bif.tab bc/ling_bifs.beam bc/gentab/iops_tab.beam $(BC_SAMPLE_BEAM) $(TEST_BEAM)
	$(ESCRIPT) bc/scripts/iopvars_gen bc/scripts/beam.src bc/scripts/bif.tab $@

bc/ling_bifs.erl: bc/scripts/bif.tab
	$(ESCRIPT) bc/scripts/bifs2_gen $< $@

bc/ling_iopvars.erl: bc/scripts/iopvars.tab bc/scripts/iopvars_erl.et
	$(ESCRIPT) bc/scripts/reorder_iopvars bc/scripts/iopvars.tab bc/scripts/hot_cold_iops bc/scripts/iopvars_erl.et $@

bc/ling_iopvars.beam: bc/ling_iopvars.erl
	$(ERLC) -o bc $<

## CORE
ifdef LING_XEN
LING_PLATFORM := xen
LING_OS := ling
ifdef LING_LINUX
CC := gcc
else ifdef LING_DARWIN
CC := x86_64-pc-linux-gcc
endif
endif

ifdef LING_POSIX
LING_PLATFORM := unix
ifdef LING_LINUX
CC := gcc
LDFLAGS += -nostdlib
LING_OS := linux
else ifdef LING_DARWIN
CC := clang
LING_OS := darwin
endif
endif

CPPFLAGS += -D_ISOC99_SOURCE -D_GNU_SOURCE
CPPFLAGS += -DLING_VER=$(LING_VER)
CPPFLAGS += -isystem core/lib
CPPFLAGS += -iquote core/include
CPPFLAGS += -iquote core/bignum
CPPFLAGS += -iquote core/arch/$(ARCH)/include

CFLAGS   := -Wall
#CFLAGS   += -Werror
CFLAGS   += -Wno-nonnull -std=gnu99
CFLAGS   += -fno-omit-frame-pointer
ifndef LING_DARWIN
CFLAGS	 += -fno-stack-protector -U_FORTIFY_SOURCE -ffreestanding
endif

# relocatable (partial linking)
LDFLAGS  += -Xlinker -r

ASFLAGS  := -D__ASSEMBLY__

ifdef LING_XEN
XEN_INTERFACE_VERSION := 0x00030205
CPPFLAGS += -DLING_XEN
#CPPFLAGS += -DLING_CONFIG_DISK
CPPFLAGS += -D__XEN_INTERFACE_VERSION__=$(XEN_INTERFACE_VERSION)

CFLAGS   += -std=gnu99
CFLAGS   += -fexcess-precision=standard -frounding-math -mfpmath=sse -msse2
CFLAGS   += -Wno-nonnull -Wno-strict-aliasing

LDFLAGS  += -T core/arch/xen/ling.lds
LDFLAGS  += -static
LDFLAGS  += -Xlinker --build-id=none
LDFLAGS  += -Xlinker --cref -Xlinker -Map=core/ling.map
LDFLAGS  += -nostdlib
LDFLAGS_FINAL += -lgcc

STARTUP_OBJ     := core/arch/xen/startup.o
STARTUP_SRC_EXT := S

LING_WITH_LWIP := 1
endif

ifdef LING_POSIX
CPPFLAGS += -DLING_POSIX
CPPFLAGS += -Wno-unknown-pragmas -Wno-int-conversion -Wno-empty-body
STARTUP_OBJ :=
ifdef LING_DARWIN
# assuming Apple LLVM version 6.0 (clang-600.0.57)
CPPFLAGS += -Wno-tautological-compare -Wno-typedef-redefinition -Wno-self-assign
endif
LING_WITH_LIBUV := 1
endif

ifdef LING_DEBUG
CFLAGS += -O0
CPPFLAGS += -DLING_DEBUG=1
CPPFLAGS += -DDEBUG_UNUSED_MEM=1
CPPFLAGS += -DTRACE_HARNESS=1
CPPFLAGS += -gdwarf-3
LDFLAGS  += -g
else
CFLAGS += -O3
ifdef LING_USE_LTO
CFLAGS += -flto
endif
endif

include core/lib/misc.mk
include core/lib/nettle.mk
include core/lib/pcre.mk

ifdef LING_WITH_LWIP
include core/lib/lwip.mk
endif

ifdef LING_WITH_LIBUV
include core/lib/libuv.mk
endif

ARCH_OBJ := $(patsubst %.c,%.o,$(wildcard core/arch/$(ARCH)/*.c))
CORE_OBJ := $(filter-out core/ling_main.%,$(patsubst %.c,%.o,$(wildcard core/*.c))) core/preload/literals.o
BIGNUM_OBJ := $(patsubst %.c,%.o,$(wildcard core/bignum/*.c))

CORE_DEP := $(patsubst %.o,%.d,$(CORE_OBJ) $(ARCH_OBJ) $(BIGNUM_OBJ) core/ling_main.o)
-include $(CORE_DEP)

ALL_OBJ += $(CORE_OBJ) $(ARCH_OBJ) $(BIGNUM_OBJ)
ALL_OBJ += core/ling_main.o

ifneq ($(STARTUP_SRC_EXT),)
# this is a c file in posix
$(STARTUP_OBJ): %.o: %.$(STARTUP_SRC_EXT) .config
	$(CC) $(ASFLAGS) $(CPPFLAGS) -c $< -o $@
endif

$(ARCH_OBJ) $(CORE_OBJ) $(BIGNUM_OBJ): %.o: %.c core/include/atom_defs.h core/include/mod_info.inc core/include/bif.h .config
	$(CC) -MMD -MP $(CFLAGS) $(CPPFLAGS) -o $@ -c $<

CORE_GENTAB_ERL := core/gentab/atoms.erl core/gentab/exp_tab.erl
CORE_GENTAB_BEAM := $(patsubst %.erl,%.beam,$(sort $(wildcard core/gentab/*.erl) $(CORE_GENTAB_ERL)))
$(CORE_GENTAB_BEAM): %.beam: %.erl
	$(ERLC) -o core/gentab $<

CORE_PRELOAD_BEAM := $(patsubst %.erl,%.beam,$(wildcard core/preload/*.erl))
$(CORE_PRELOAD_BEAM): %.beam: %.erl .config
	$(ERLC) -DLING_VER=\"$(LING_VER)\" -DLING_PLATFORM=$(LING_PLATFORM) -DLING_OS=$(LING_OS) -o core/preload $<

# use pattern rule (%) to avoid multiple premod_gen invocation in parralel builds
CORE_INCLUDES = core/premod.%nc core/code_base.%nc core/include/mod_info.%nc core/preload/l%terals.c core/catch_tab.%nc
$(CORE_INCLUDES): core/gentab/atoms.beam core/gentab/exp_tab.beam core/include/atom_defs.h $(CORE_PRELOAD_BEAM) bc/scripts/bif.tab
	$(ESCRIPT) core/scripts/premod_gen core/preload core/premod.inc core/code_base.inc core/include/mod_info.inc core/preload/literals.c core/catch_tab.inc copy

core/gentab/exp_tab.erl: $(CORE_PRELOAD_BEAM) bc/scripts/bif.tab bc/ling_iopvars.beam
	$(ESCRIPT) core/scripts/exptab_gen core/preload bc/scripts/bif.tab $@

core/include/atom_defs%h core/atoms%inc core/gentab/atoms%erl: core/scripts/atoms.tab core/gentab/exp_tab.beam
	$(ESCRIPT) core/scripts/atoms_gen core/scripts/atoms.tab core/preload core/include/atom_defs.h core/atoms.inc core/gentab/atoms.erl

core/ling_main.c: core/scripts/ling_main_c.et core/scripts/hot_cold_iops $(CORE_GENTAB_BEAM) .config
	$(ESCRIPT) core/scripts/main_gen core/scripts/ling_main_c.et core/scripts/hot_cold_iops $@

core/ling_main.o: core/ling_main.c core/include/atom_defs.h core/include/bif.h core/include/mod_info.inc core/premod.inc
	$(CC) -MMD -MP $(CFLAGS) $(CPPFLAGS) $(F_NO_REORDER_BLOCKS) -o $@ -c $<

core/include/bif.h: bc/scripts/bif.tab
	$(ESCRIPT) core/scripts/bifs_gen $< $@

bc/scripts/bif.tab: bc/scripts/bif_common.tab bc/scripts/bif_$(ARCH).tab .config
	cat bc/scripts/bif_common.tab bc/scripts/bif_$(ARCH).tab > $@

core/vmling.o: $(STARTUP_OBJ) $(ALL_OBJ)
	$(CC) -o $@ $(STARTUP_OBJ) $(ALL_OBJ) $(CFLAGS) $(LDFLAGS) $(LDFLAGS_FINAL)

## APPS
include apps/apps.mk

## RAILING
railing/railing: $(patsubst %.erl,%.beam,$(wildcard railing/*.erl)) railing/escriptize $(APPS_ALL) core/vmling.o
	$(ESCRIPT) ./railing/escriptize $(ARCH)

railing/%.beam: railing/%.erl .config
	$(ERLC) -DLING_VER=\"$(LING_VER)\" -DARCH=\'$(ARCH)\' -DOTP_VER=\"$(OTP_VER)\" -o railing $<

.config:

clean:
	@rm -rf \
		$(TEST_BEAM) $(BC_BEAM) $(BC_SAMPLE_BEAM) \
		bc/gentab/iops_tab.erl bc/scripts/iopvars.tab \
		bc/ling_iopvars.erl bc/ling_iopvars.beam \
		bc/ling_bifs.erl bc/ling_bifs.beam \
		$(STARTUP_OBJ) $(ALL_OBJ) \
		$(CORE_GENTAB_BEAM) $(CORE_PRELOAD_BEAM) \
		core/premod.inc core/code_base.inc core/include/mod_info.inc \
		core/preload/literals.c core/catch_tab.inc \
		core/gentab/exp_tab.erl \
		core/include/atom_defs.h core/atoms.inc core/gentab/atoms.erl \
		core/ling_main.c core/ling_main.o \
		core/include/bif.h \
		core/vmling.o \
		$(APPS_ALL) \
		railing/railing railing/railing.beam railing/getopt.beam \
		$(CORE_DEP) $(LIBUV_DEP) $(LWIP_DEP) $(MISC_DEP) $(NETTLE_DEP) $(PCRE_DEP)

.PHONY: default test play install clean
