# MIT License. Copyright (c) 2026-present K. S. Ernest (iFire) Lee
# (Permission notice as in the other files of this package.)
"""
Textures on the wire: Basis Universal in a KTX2 file, never a codec on the blocklist. No `bpy` here.

Blocklist (operator rule): ETC1, ETC1S (Basis's BasisLZ codec), ETC2 and DXT5 (BC3) are banned, both as the codec a
texture is stored in and as a GPU format one is transcoded to. `check_ktx2` refuses a file that uses one; `encode`
only makes allowed codecs: UASTC or XUASTC LDR (transcodes to BC7 or ASTC), UASTC HDR (BC6H or ASTC HDR).
"""

import struct
import subprocess
import tempfile
import os
from typing import Optional

KTX2_MAGIC = b"\xabKTX 20\xbb\r\n\x1a\n"
SCHEME_BASISLZ = 1  # the supercompression scheme of ETC1S
MODEL_ETC1S = 163  # KHR_DF_MODEL_ETC1S
# vkFormat values that are banned as a stored format: BC3 (DXT5) and the ETC2 / EAC families
BANNED_VK_FORMATS = frozenset({133, 134, *range(147, 157)})
# GPU targets a transcode must never choose
BANNED_TARGETS = frozenset({"ETC1", "ETC2", "ETC1S", "DXT5", "BC3"})


class BannedTexture(ValueError):
    """The texture uses a codec or format on the blocklist."""


def check_ktx2(data: bytes) -> None:
    """Raise `BannedTexture` for ETC1S / BasisLZ, ETC1, ETC2 or DXT5 content, `ValueError` for a file that is no KTX2."""
    if len(data) < 80 or data[:12] != KTX2_MAGIC:
        raise ValueError("not a KTX2 file")
    vk_format = struct.unpack_from("<I", data, 12)[0]
    scheme = struct.unpack_from("<I", data, 44)[0]
    dfd_offset, dfd_length = struct.unpack_from("<II", data, 48)
    if vk_format in BANNED_VK_FORMATS:
        raise BannedTexture(f"vkFormat {vk_format} (ETC2/EAC/DXT5) is banned")
    if scheme == SCHEME_BASISLZ:
        raise BannedTexture("BasisLZ supercompression (ETC1S) is banned")
    if dfd_length >= 16 and dfd_offset + 16 <= len(data) and data[dfd_offset + 12] == MODEL_ETC1S:
        raise BannedTexture("colour model ETC1S is banned")


def pick_target(available: "list[str]", preferred: "list[str]") -> Optional[str]:
    """The first preferred GPU format the device has that is not banned, or None."""
    for name in preferred:
        if name.upper() not in BANNED_TARGETS and name in available:
            return name
    return None


def encode(png: str, out: str, srgb: bool, hdr: bool = False, basisu: str = "basisu") -> int:
    """PNG (or EXR/HDR when `hdr`) to KTX2 with mipmaps; returns the size. Colour maps: XUASTC 8x6, data maps (normals,
    roughness...): XUASTC 6x6, both from the LDR set; HDR: UASTC HDR 4x4. Every output is checked against the blocklist.
    """
    if hdr:
        mode = ["-hdr_4x4"]
    elif srgb:
        mode = ["-ldr_8x6i", "-quality", "40", "-srgb"]
    else:
        mode = ["-ldr_6x6i", "-quality", "40", "-linear"]
    subprocess.run([basisu, "-ktx2", "-mipmap", *mode, "-output_file", out, png], check=True, capture_output=True)
    data = open(out, "rb").read()
    check_ktx2(data)
    return len(data)
