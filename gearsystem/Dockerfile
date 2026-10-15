# Emscripten 3.1.46, the version libretro's own build image pins, by digest so a rebuild uses the
# same toolchain (the same image as snes/ and clownmdemu/).
FROM emscripten/emsdk:3.1.46@sha256:2491bc4bf6caf8c41993660822341bc72759cb577363dfe0781f0a2d05f7d357

# The repo is mounted from the host under another owner, which git otherwise refuses to read.
RUN git config --system --add safe.directory '*'
