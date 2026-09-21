# Pin file for the air-gapped aider bundle.
#
# Every network fetch in build-bundle.ps1 is verified against a hash recorded
# here, so a reviewer can audit exactly what enters the air gap. Do not let the
# build script resolve "latest" at build time -- bundles must be reproducible.
#
# To refresh the Python pin:
#   curl -sSL https://api.github.com/repos/astral-sh/python-build-standalone/releases/latest
# then copy the tag, the 3.12 x86_64-pc-windows-msvc install_only asset version,
# and that asset's sha256 digest.

@{
    # --- Target interpreter -------------------------------------------------
    # 3.12 is chosen deliberately:
    #   * puts us on the python_version >= "3.11" side of every marker in
    #     requirements.txt (numpy>=2.3,<2.5 / scipy>=1.16.1,<1.18 / tree-sitter 0.25.2)
    #   * stays BELOW 3.13, so audioop-lts is never pulled and stdlib audioop
    #     still satisfies pydub
    #   * matches docker/Dockerfile (python:3.12-slim-bookworm)
    #   * cp312 win_amd64 wheel coverage is complete for the whole dep tree;
    #     cp313/cp314 coverage is still patchy in the tail
    PythonVersion = '3.12.14'
    PythonTag     = 'cp312'
    Platform      = 'win_amd64'

    # --- python-build-standalone (portable CPython) -------------------------
    PbsTag        = '20260901'
    PbsSha256     = 'e90c1b6419da3bd812dd73bb3de40287a21abf153438147639ec5e20375ea93f'

    # --- Bundle format ------------------------------------------------------
    # install.ps1 refuses a bundle whose format it does not understand.
    BundleFormat  = 1

    # --- Extras -------------------------------------------------------------
    # Core only. 'help' pulls torch (+2.5-3 GB) from a separate index,
    # 'browser' pulls streamlit+pyarrow, 'playwright' needs a separate ~150 MB
    # browser transfer. All out of scope.
    Extras        = @()

    # --- Sanity floors for the wheel-content gate ---------------------------
    # The aider wheel ships coders/queries/resources as PACKAGE DATA whose file
    # list comes from setuptools_scm's git finder. A build from a tree without
    # .git produces a wheel that imports but has no coders and no repo map.
    MinScmQueries = 55
    MinCoderFiles = 30
}
