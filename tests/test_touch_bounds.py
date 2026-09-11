"""Run the core's actual pointer branch against two-screen boundary cases; no ROM."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / '.local/azahar-src/src/citra_libretro/input/mouse_tracker.cpp'


@unittest.skipUnless(SOURCE.exists(), 'Run source preparation first')
class TouchBoundsTests(unittest.TestCase):
    def test_absolute_pointer_bounds_and_center(self):
        source = SOURCE.read_text()
        bounds = source.split('static bool IsWithinTouchscreen', 1)[1].split('MouseTracker::MouseTracker()', 1)[0]
        branches = [source.split(f'if (LibRetro::settings.enable_{kind}_touchscreen) {{', 1)[1].split('\n    }', 1)[0]
                    for kind in ('mouse', 'touch')]
        prelude = r'''
#include <algorithm>
#include <cassert>
namespace Settings {
enum class StereoRenderOption { Off, SideBySide, SideBySideFull, CardboardVR };
struct { struct { StereoRenderOption GetValue() { return StereoRenderOption::Off; } } render_3d; } values;
}
namespace Layout {
struct Rect { unsigned left=40, top=240, right=360, bottom=480; unsigned GetWidth() const { return right-left; } };
struct FramebufferLayout { Rect bottom_screen; unsigned width=400; struct { unsigned bottom_screen_right_eye=0; } cardboard; };
}
enum { RETRO_DEVICE_MOUSE, RETRO_DEVICE_POINTER, RETRO_DEVICE_ID_MOUSE_LEFT,
       RETRO_DEVICE_ID_POINTER_X, RETRO_DEVICE_ID_POINTER_Y, RETRO_DEVICE_ID_POINTER_PRESSED };
int pointerX=0, pointerY=0; bool pressed=false;
namespace LibRetro {
int CheckInput(int, int, int, int id) {
    if(id==RETRO_DEVICE_ID_POINTER_X) return pointerX;
    if(id==RETRO_DEVICE_ID_POINTER_Y) return pointerY;
    return pressed;
}
}
'''
        checks = r'''
int main() {
    auto at = [](int px, int py, bool down=true) {
        pointerX=px; pointerY=py; pressed=down; return update();
    };
    assert(at(0,16384)); assert(x==160 && y==120); // Bottom-screen center.
    assert(!at(0,-16384)); // Top screen must not reuse the last touch.
    assert(!at(-32767,16384)); assert(!at(32767,16384)); // Side gutters.
    assert(at(0,0)); assert(x==160 && y==0); // Normalized zero is a real point.
    assert(at(0,0)); assert(!at(0,0,false)); // Stationary press and release.
    assert(at(-26213,1)); assert(x==0 && y==0); // First lower-screen pixel.
    assert(at(26050,32766)); assert(x==359-40 && y==479-240); // Last pixel.
    assert(!at(26214,16384)); assert(!at(0,32767)); // Right/bottom excluded edges.
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            for branch in branches:
                code = prelude + 'static bool IsWithinTouchscreen' + bounds
                code += '\nint x=0,y=0,lastMouseX=0,lastMouseY=0;\nbool update() {\n'
                code += 'bool state=false; int bufferWidth=400,bufferHeight=480; Layout::FramebufferLayout layout;\n'
                code += branch + '\nreturn state;\n}\n' + checks
                (folder / 'touch.cpp').write_text(code)
                subprocess.run(['xcrun', 'clang++', '-std=c++20', str(folder / 'touch.cpp'), '-o', str(folder / 'touch')], check=True)
                subprocess.run([str(folder / 'touch')], check=True)


if __name__ == '__main__':
    unittest.main()
