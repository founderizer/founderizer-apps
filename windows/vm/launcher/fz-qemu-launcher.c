//
// Copyright © 2021 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// Changed for Founderizer on 13 November 2026: this file is a shorter form of
// QEMULauncher/main.c and QEMULauncher/Bootstrap.c of UTM 5.0.8
// (github.com/utmapp/UTM, tag v5.0.8). It keeps their loading of a tool library
// and their order of entry points; it does not fork and does not watch its parent.
//
// Runs one of UTM's own QEMU tools outside UTM's window (README.md, "Why a launcher").
//
//   fz-qemu-launcher <tool library> <arguments...>
//
// UTM ships QEMU, qemu-img and swtpm as libraries, and starts each one through
// its QEMULauncher helper. That helper is signed to inherit UTM's sandbox, so
// macOS stops it when anything but UTM starts it. This program loads the tool
// library and calls its entry point, as UTM's helper does. build.sh signs it
// ad hoc with the one entitlement that QEMU's hypervisor accelerator needs.
// The tools then run outside UTM's sandbox, as the user's own processes.

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

extern char **environ;

typedef int (*main_function)(int, const char *[]);
typedef int (*init_function)(int, const char *[], const char *[]);
typedef void (*void_function)(void);
typedef int (*swtpm_function)(int, const char *[], const char *, const char *);

int main(int argc, const char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: fz-qemu-launcher <tool library> <arguments...>\n");
        return 2;
    }
    void *library = dlopen(argv[1], RTLD_LOCAL | RTLD_LAZY | RTLD_FIRST);
    if (library == NULL) {
        fprintf(stderr, "cannot load %s: %s\n", argv[1], dlerror());
        return 1;
    }
    main_function tool_main = (main_function)dlsym(library, "main");
    init_function qemu_init = (init_function)dlsym(library, "qemu_init");
    void_function qemu_main_loop = (void_function)dlsym(library, "qemu_main_loop");
    void_function qemu_cleanup = (void_function)dlsym(library, "qemu_cleanup");
    swtpm_function swtpm_main = (swtpm_function)dlsym(library, "swtpm_main");

    // The library sees its own path as argv[0], as under UTM.
    int count = argc - 1;
    const char **arguments = &argv[1];
    if (qemu_init != NULL) {
        qemu_init(count, arguments, (const char **)environ);
    }
    if (tool_main != NULL) {
        return tool_main(count, arguments);
    }
    if (swtpm_main != NULL) {
        return swtpm_main(count, arguments, "swtpm", "socket");
    }
    if (qemu_main_loop != NULL && qemu_cleanup != NULL) {
        qemu_main_loop();
        qemu_cleanup();
        return 0;
    }
    fprintf(stderr, "%s has no entry point that this launcher knows\n", argv[1]);
    return 1;
}
