"""Untrusted image -> clean JPEG. Pillow is imported lazily to keep cold start fast."""

from __future__ import annotations

import io

MAX_LONG_SIDE = 1600
JPEG_QUALITY = 82
MAX_PIXELS = 64_000_000  # ~ 9000x7000; bigger images are rejected before decoding
MIN_SIDE = 32
ALLOWED_FORMATS = {"JPEG", "PNG", "WEBP"}


class ImageRejected(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code  # "invalid_image" | "unsupported_format" | "image_too_large" | "image_too_small"


def process_image(data: bytes) -> tuple[bytes, int, int]:
    """Validate + normalize. Returns (jpeg_bytes, width, height). Raises ImageRejected.

    Auto-rotates by EXIF orientation, drops all metadata (EXIF/ICC/XMP), flattens alpha,
    resizes so the long side <= 1600 px and re-encodes as JPEG q82.
    """
    import warnings

    from PIL import Image, ImageOps

    Image.MAX_IMAGE_PIXELS = MAX_PIXELS
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            # Pass 1: structural check.
            with Image.open(io.BytesIO(data)) as probe:
                fmt = probe.format
                if fmt not in ALLOWED_FORMATS:
                    raise ImageRejected("unsupported_format")
                w, h = probe.size
                if w * h > MAX_PIXELS:
                    raise ImageRejected("image_too_large")
                if w < MIN_SIDE or h < MIN_SIDE:
                    raise ImageRejected("image_too_small")
                probe.verify()

            # Pass 2: real decode (verify() leaves the image unusable).
            with Image.open(io.BytesIO(data)) as img:
                if img.format != fmt:
                    raise ImageRejected("invalid_image")
                if fmt == "JPEG":
                    # DCT-domain downscale while decoding: big memory saving for huge photos.
                    img.draft("RGB", (MAX_LONG_SIDE * 2, MAX_LONG_SIDE * 2))
                img.seek(0)  # first frame of animated WEBP/PNG
                img.load()
                img = ImageOps.exif_transpose(img)
                if img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info):
                    rgba = img.convert("RGBA")
                    bg = Image.new("RGB", rgba.size, (0, 0, 0))
                    bg.paste(rgba, mask=rgba.getchannel("A"))
                    img = bg
                else:
                    img = img.convert("RGB")
                img.thumbnail((MAX_LONG_SIDE, MAX_LONG_SIDE), Image.Resampling.LANCZOS)
                out = io.BytesIO()
                img.save(out, "JPEG", quality=JPEG_QUALITY, optimize=True, progressive=True)
                return out.getvalue(), img.width, img.height
    except ImageRejected:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise ImageRejected("image_too_large")
    except Exception:
        # UnidentifiedImageError, truncated files, SyntaxError from broken headers, etc.
        raise ImageRejected("invalid_image")
