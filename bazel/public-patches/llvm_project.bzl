"""Module extension to configure LLVM"""

load("@llvm-raw//utils/bazel:configure.bzl", _llvm_configure = "llvm_configure")

# This fork targets Apple silicon and nothing else, so it configures one
# backend. AArch64 covers both halves of the job: the arm64 host code the
# compiler emits, and the AArch64 MC layer the Apple GPU path leans on -- AIR
# is emitted as bitcode against an air64 triple, not through a registered
# LLVM target, so dropping backends does not touch it.
#
# X86 and RISCV were 57 MB of objects and several thousand compile actions for
# code this machine will never execute. Nothing needs deleting to remove them:
# InitializeAllTargets() expands from LLVM's generated Targets.def, so it now
# registers AArch64 alone and every call site in KGEN/tools keeps compiling
# unchanged.
#
# Adding one back is a tag, not an edit -- see the 'extra_targets' attribute
# below, or append here if it should be unconditional.
BACKENDS = [
    "AArch64",
]

def _llvm_project_impl(module_ctx):
    targets = {t: None for t in BACKENDS}
    for mod in module_ctx.modules:
        for tag in mod.tags.configure:
            for t in tag.extra_targets:
                targets[t] = None

    _llvm_configure(
        name = "llvm-project",
        targets = sorted(targets.keys()),
    )

    return module_ctx.extension_metadata(reproducible = True)

_configure = tag_class(
    attrs = {
        "extra_targets": attr.string_list(
            doc = "Additional LLVM backends to configure alongside default backends.",
        ),
    },
)

# NOTE: exported as `llvm_configure` (not `llvm_project`) on purpose: the
# canonical bzlmod repo name is derived from the extension symbol, so this keeps
# it `@@+llvm_configure+llvm-project`. Renaming
# the symbol would rename the repo and break those references.
llvm_configure = module_extension(
    implementation = _llvm_project_impl,
    tag_classes = {"configure": _configure},
    doc = "Configures LLVM as `@llvm-project` with the selected backends.",
)
