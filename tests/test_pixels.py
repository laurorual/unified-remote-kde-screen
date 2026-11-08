"""Known-color regressions for the QImage formats returned by KWin ScreenShot2."""
import importlib.util
import io
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from PIL import Image

spec = importlib.util.spec_from_file_location(
    'pixel_streamer', Path(__file__).resolve().parents[1] / 'kde_screen_remote_streamer.py')
streamer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(streamer)


class PixelFormatTests(unittest.TestCase):
    def test_primary_colors_and_vscode_blue_in_byte_ordered_formats(self):
        colors = ((255, 0, 0), (0, 255, 0), (0, 0, 255), (0, 122, 204))
        for fmt in (13, 16, 17, 18):
            for byteorder in ('little', 'big'):
                with self.subTest(format=fmt, byteorder=byteorder):
                    data = b''.join(bytes(rgb) + (b'' if fmt == 13 else b'\xff')
                                    for rgb in colors)
                    decoded = streamer.decode_frame(data, 4, 1, len(data), fmt,
                                                    byteorder=byteorder)
                    self.assertEqual([decoded.getpixel((x, 0)) for x in range(4)], list(colors))

    def test_legacy_native_endian_formats_keep_correct_channels(self):
        for fmt in (4, 5, 6):
            for order, data in [('little', bytes((204, 122, 0, 255))),
                                ('big', bytes((255, 0, 122, 204)))]:
                with self.subTest(format=fmt, byteorder=order):
                    decoded = streamer.decode_frame(data, 1, 1, 4, fmt, byteorder=order)
                    self.assertEqual(decoded.getpixel((0, 0)), (0, 122, 204))

    def test_premultiplied_alpha_is_unpremultiplied(self):
        fixtures = [(6, 'little', bytes((64, 32, 16, 128))),
                    (6, 'big', bytes((128, 16, 32, 64))),
                    (18, 'little', bytes((16, 32, 64, 128)))]
        for fmt, order, data in fixtures:
            with self.subTest(format=fmt, byteorder=order):
                color = streamer.decode_frame(data, 1, 1, 4, fmt,
                                              byteorder=order).getpixel((0, 0))
                for actual, expected in zip(color, (32, 64, 128)):
                    self.assertLessEqual(abs(actual - expected), 1)

    def test_straight_alpha_does_not_brighten_colors(self):
        decoded = streamer.decode_frame(bytes((16, 32, 64, 128)), 1, 1, 4, 17)
        self.assertEqual(decoded.getpixel((0, 0)), (16, 32, 64))

    def test_stride_padding_is_not_interpreted_as_pixels(self):
        data = bytes((0, 122, 204, 255)) + b'padding!' + bytes((255, 0, 0, 255)) + b'padding!'
        decoded = streamer.decode_frame(data, 1, 2, 12, 16)
        self.assertEqual([decoded.getpixel((0, y)) for y in range(2)],
                         [(0, 122, 204), (255, 0, 0)])

    def test_unknown_formats_are_rejected_instead_of_guessing_channel_order(self):
        with self.assertRaisesRegex(ValueError, 'Unsupported KWin pixel format: 999'):
            streamer.decode_frame(b'\0' * 4, 1, 1, 4, 999)

    def test_malformed_frame_is_rejected(self):
        for data, width, height, stride in [(b'\0', 1, 1, 4), (b'\0' * 4, 2, 1, 4),
                                             (b'\0' * 4, 1, 0, 4)]:
            with self.subTest(size=(width, height), stride=stride):
                with self.assertRaisesRegex(ValueError, 'Invalid KWin frame'):
                    streamer.decode_frame(data, width, height, stride, 16)

    def test_rgbx_vscode_blue_stays_blue_in_the_final_jpeg(self):
        pixels = bytes((0, 122, 204, 255)) * 32 * 32
        with patch.object(streamer, 'read_zoom', return_value=1):
            payload, *_ = streamer.encode_jpeg(pixels, 32, 32, 128, None, None,
                                              32, 95, pixel_format=16)
        actual = Image.open(io.BytesIO(payload)).getpixel((16, 16))
        for component, expected in zip(actual, (0, 122, 204)):
            self.assertLessEqual(abs(component - expected), 3)

    def test_capture_preserves_pixel_format_metadata(self):
        capture = object.__new__(streamer.KWinCapture)
        capture.options = {}

        def fake_capture(options, fd, **kwargs):
            os.write(fd, bytes((0, 122, 204, 255)))
            return dict(width=1, height=1, stride=4, format=16, screen='DP-1')

        capture.iface = SimpleNamespace(get_dbus_method=lambda *args: fake_capture)
        with patch.object(streamer.dbus.types, 'UnixFd', side_effect=lambda fd: fd):
            result = capture.capture_active()
        self.assertEqual(result[-1], 16)
        self.assertEqual(streamer.decode_frame(result[0], result[1], result[2], result[3],
                                               result[-1]).getpixel((0, 0)), (0, 122, 204))


if __name__ == '__main__':
    unittest.main()
