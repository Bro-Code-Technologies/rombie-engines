// Rombie's netplay engine, Worker side. The build appends this to the engine's Emscripten output
// (--post-js), so the one built .js file is the Worker script: it owns the module, and the page
// reaches the engine only through the messages below (README.md lists them).
//
// SPDX-License-Identifier: GPL-2.0-or-later

;(function () {
  const PORTS = 4
  // Per port and frame: buttons (the libretro joypad bitmask), left x, left y, right x, right y.
  const VALUES_PER_PORT = 5
  const VALUES_PER_FRAME = PORTS * VALUES_PER_PORT

  const early = []
  let started = false

  const str = (s) => stringToNewUTF8(s)

  function copyOut(ptr, bytes) {
    return HEAPU8.slice(ptr, ptr + bytes).buffer
  }

  function withHeapCopy(buffer, fn) {
    const bytes = new Uint8Array(buffer)
    const ptr = _malloc(Math.max(1, bytes.length))
    HEAPU8.set(bytes, ptr)
    try {
      return fn(ptr, bytes.length)
    } finally {
      _free(ptr)
    }
  }

  function setOption(key, value) {
    const k = str(key)
    const v = value == null ? 0 : str(String(value))
    _np_set_option(k, v)
    _free(k)
    if (v) _free(v)
  }

  function takeFrame() {
    if (!_np_take_frame_ready()) return null
    const width = _np_frame_width()
    const height = _np_frame_height()
    return { width, height, pixels: copyOut(_np_frame_pixels(), width * height * 4) }
  }

  function takeAudio() {
    const length = _np_audio_length()
    if (!length) return null
    const samples = HEAP16.slice(_np_audio_samples() >> 1, (_np_audio_samples() >> 1) + length).buffer
    _np_audio_clear()
    return samples
  }

  const handlers = {
    load(msg) {
      const name = String(msg.name || 'game').replace(/[/\\]/g, '_')
      let path = '/' + name
      if (msg.files) {
        // A disc's files, as Blobs: mounted read-only and read as the core asks, never copied
        // whole into memory. name is the one to load (a .cue names the others).
        FS.mkdir('/game')
        FS.mount(WORKERFS, { blobs: msg.files.map((file) => ({ name: String(file.name).replace(/[/\\]/g, '_'), data: file.data })) }, '/game')
        path = '/game/' + name
      } else {
        FS.writeFile(path, new Uint8Array(msg.rom))
      }
      for (const file of msg.system || []) {
        FS.writeFile('/system/' + String(file.name).replace(/[/\\]/g, '_'), new Uint8Array(file.data))
      }
      for (const [key, value] of Object.entries(msg.options || {})) setOption(key, value)
      // The core starts only now, with its system folder and options in place: some look for their BIOS as they
      // start (pcsx_rearmed does), as they would in a frontend whose system folder is already full.
      _np_init()
      const p = str(path)
      const loaded = _np_load_game(p)
      _free(p)
      if (!loaded) throw new Error('the core could not load ' + name)
      ;(msg.devices || []).forEach((device, port) => {
        if (device != null) _np_set_port_device(port, device)
      })
      if (msg.sram) handlers.sramSet(msg)
      return {
        type: 'loaded',
        library: UTF8ToString(_np_library_name()) + ' ' + UTF8ToString(_np_library_version()),
        fps: _np_fps(),
        sampleRate: _np_sample_rate(),
        baseWidth: _np_base_width(),
        baseHeight: _np_base_height(),
        aspectRatio: _np_aspect_ratio(),
        stateSize: _np_state_size(),
        sramSize: _np_sram_size(0),
        frame: _np_frame_number(),
      }
    },

    // Runs frames from `from`: when that is behind the engine, it first rolls back to it from
    // its ring. Sound is kept for frames from `audioFrom` on, and only the last frame is drawn.
    run(msg) {
      const values = new Int16Array(msg.inputs)
      const count = values.length / VALUES_PER_FRAME
      if (msg.from !== _np_frame_number() && !_np_rollback(msg.from)) {
        throw new Error('frame ' + msg.from + ' is not in the ring (engine at ' + _np_frame_number() + ')')
      }
      const audioFrom = msg.audioFrom ?? msg.from
      const draw = msg.video !== false
      // State, game memory and picture, per frame: the state and memory as they stand before the
      // frame runs, the picture it draws.
      const hashes = msg.hashes ? new Uint32Array(count) : null
      const memoryHashes = msg.hashes ? new Uint32Array(count) : null
      const videoHashes = msg.hashes ? new Uint32Array(count) : null
      _np_set_video_hashing(msg.hashes ? 1 : 0)
      _np_audio_clear()
      const start = performance.now()
      for (let i = 0; i < count; i++) {
        const frame = msg.from + i
        const base = i * VALUES_PER_FRAME
        for (let port = 0; port < PORTS; port++) {
          const o = base + port * VALUES_PER_PORT
          _np_set_input(port, values[o] & 0xffff, values[o + 1], values[o + 2], values[o + 3], values[o + 4])
        }
        _np_set_av_enabled(draw && i === count - 1 ? 1 : 0, frame >= audioFrom ? 1 : 0)
        if (memoryHashes) memoryHashes[i] = _np_memory_hash() >>> 0
        if (!_np_run_frame()) throw new Error('the core could not save the state before frame ' + frame)
        if (hashes) {
          hashes[i] = _np_ring_hash(frame) >>> 0
          videoHashes[i] = _np_video_hash() >>> 0
        }
      }
      const engineMs = performance.now() - start
      const video = draw ? takeFrame() : null
      const audio = takeAudio()
      const transfer = []
      if (video) transfer.push(video.pixels)
      if (audio) transfer.push(audio)
      if (hashes) transfer.push(hashes.buffer, memoryHashes.buffer, videoHashes.buffer)
      return [{ type: 'ran', frame: _np_frame_number(), video, audio, hashes, memoryHashes, videoHashes, engineMs }, transfer]
    },

    checksum(msg) {
      const hash = _np_ring_hash(msg.frame) >>> 0
      return { type: 'checksum', frame: msg.frame, hash: hash || null }
    },

    save() {
      const size = _np_state_size()
      const ptr = _malloc(size)
      try {
        if (!_np_save_state(ptr)) throw new Error('the core could not save its state')
        const data = copyOut(ptr, size)
        return [{ type: 'state', frame: _np_frame_number(), data }, [data]]
      } finally {
        _free(ptr)
      }
    },

    loadState(msg) {
      const ok = withHeapCopy(msg.data, (ptr, size) => _np_load_state(ptr, size, msg.frame ?? 0))
      if (!ok) throw new Error('the core did not accept the state (' + msg.data.byteLength + ' bytes, expected ' + _np_state_size() + ')')
      return { type: 'stateLoaded', frame: _np_frame_number() }
    },

    // `memory` is a libretro memory id, RETRO_MEMORY_SAVE_RAM (0) when absent (`id` is the request's own): Gearsystem's
    // link also has its two consoles' save RAM as 0x100 and 0x200.
    sramGet(msg) {
      const id = msg.memory ?? 0
      const size = _np_sram_size(id)
      const data = size ? copyOut(_np_sram_data(id), size) : null
      return [{ type: 'sram', data }, data ? [data] : []]
    },

    sramSet(msg) {
      const id = msg.memory ?? 0
      const size = _np_sram_size(id)
      const bytes = new Uint8Array(msg.sram || msg.data)
      if (!size) return { type: 'sramSet', written: 0 }
      HEAPU8.set(bytes.subarray(0, size), _np_sram_data(id))
      return { type: 'sramSet', written: Math.min(size, bytes.length) }
    },

    options(msg) {
      for (const [key, value] of Object.entries(msg.options || {})) setOption(key, value)
      return { type: 'options' }
    },

    device(msg) {
      _np_set_port_device(msg.port, msg.device)
      return { type: 'device' }
    },

    reset() {
      _np_reset()
      return { type: 'reset', frame: _np_frame_number() }
    },

    // Timings measured inside the engine, so the page's message round trips are left out.
    bench(msg) {
      const iterations = msg.iterations || 600
      _np_set_av_enabled(1, 1)
      const result = {
        type: 'bench',
        stateSize: _np_state_size(),
        serializeMs: _np_bench(iterations, 0),
        unserializeMs: _np_bench(iterations, 1),
        frameMs: _np_bench(iterations, 2),
      }
      _np_audio_clear()
      return result
    },

    unload() {
      _np_unload()
      return { type: 'unloaded' }
    },
  }

  function handle(msg) {
    try {
      const handler = handlers[msg && msg.type]
      if (!handler) throw new Error('unknown message ' + (msg && msg.type))
      const result = handler(msg)
      const [reply, transfer] = Array.isArray(result) ? result : [result, []]
      reply.id = msg.id
      postMessage(reply, transfer)
    } catch (err) {
      postMessage({ type: 'error', id: msg && msg.id, request: msg && msg.type, message: String(err && err.message || err) })
    }
  }

  // Messages that arrive while the module is still compiling wait here rather than being lost.
  self.onmessage = (event) => {
    if (started) handle(event.data)
    else early.push(event.data)
  }

  function start() {
    FS.mkdir('/system')
    FS.mkdir('/save')
    started = true
    postMessage({ type: 'ready' })
    for (const msg of early.splice(0)) handle(msg)
  }

  if (runtimeInitialized) start()
  else Module.onRuntimeInitialized = start
})()
