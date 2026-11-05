"""Run with: python3 -m unittest discover -s tests -v (no desktop input is sent)."""
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import patch

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


streamer = load("streamer", "kde_screen_remote_streamer.py")


class ZoomTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        image = Image.new("RGBA", (320, 180))
        image.putdata([(round(x * 255 / 319), 0, 0, 255)
                       for y in range(180) for x in range(320)])
        cls.pixels = image.tobytes("raw", "BGRA")

    def encode(self, geometry, cursor, zoom):
        with patch.object(streamer, "read_zoom", return_value=zoom):
            return streamer.encode_jpeg(self.pixels, 320, 180, 1280,
                                        geometry, cursor, 160, 90)

    def test_second_monitor_follows_horizontally_at_both_zoom_levels(self):
        for zoom in (2, 3):
            left = self.encode((1920, 0, 1920, 1080), (2496, 540), zoom)
            right = self.encode((1920, 0, 1920, 1080), (3264, 540), zoom)
            self.assertAlmostEqual(left[4], 0.3)
            self.assertAlmostEqual(right[4], 0.7)
            a = Image.open(io.BytesIO(left[0])).getpixel((80, 45))[0]
            b = Image.open(io.BytesIO(right[0])).getpixel((80, 45))[0]
            self.assertLess(a, 100)
            self.assertGreater(b, 150)

    def test_local_position_matches_on_first_and_second_monitors(self):
        first = self.encode((0, 0, 1920, 1080), (768, 324), 2)
        second = self.encode((1920, 0, 1920, 1080), (2688, 324), 2)
        self.assertEqual(first[0], second[0])

    def test_negative_origin_and_scaled_logical_geometry(self):
        result = self.encode((-1280, -720, 1280, 720), (-640, -360), 3)
        self.assertEqual(result[4:], (0.5, 0.5))

    def test_missing_geometry_uses_center_instead_of_wrong_screen_origin(self):
        result = self.encode(None, (2800, 400), 2)
        self.assertEqual(result[4:], (0.5, 0.5))



if __name__ == "__main__":
    unittest.main()
