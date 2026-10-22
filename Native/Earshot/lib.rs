#![no_std]

use core::{panic::PanicInfo, slice};
use earshot::{DefaultPredictor, Detector};

unsafe extern "C" { fn abort() -> !; }
#[panic_handler]
fn panic(_: &PanicInfo<'_>) -> ! { unsafe { abort() } }

#[unsafe(no_mangle)]
pub extern "C" fn ESVoiceActivityDetectorSize() -> usize { size_of::<Detector>() }

// Swift owns a suitably aligned allocation and serializes every call. No heap
// allocation, Rust standard library, or unwind runtime crosses this boundary.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ESVoiceActivityDetectorInit(detector: *mut Detector) {
    unsafe { detector.write(Detector::new(DefaultPredictor::new())) };
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ESVoiceActivityDetectorReset(detector: *mut Detector) {
    unsafe { &mut *detector }.reset();
}
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ESVoiceActivityDetectorPredictF32(detector: *mut Detector, frame: *const f32, len: usize) -> f32 {
    unsafe { &mut *detector }.predict_f32(unsafe { slice::from_raw_parts(frame, len) })
}
