# VideoSpliter

Interactive PowerShell tool to cut clips out of a video with ffmpeg.

Run `extrait.bat` (or `powershell -ExecutionPolicy Bypass -File extrait.ps1`), then answer the prompts:
video file, start/end time (empty end = end of video), optional title, fade in/out, output name.
Several parts can be extracted from the same video.

- No title and no fade: cut without re-encoding (fast, start snaps to the nearest keyframe).
- Title and/or fade: re-encode (H.264 + AAC), audio channel layout is preserved.
- If ffmpeg is not found, the script asks for its path.

Clips are written to the `extraits` folder (see `extrait.ps1` to change it).
