use std::cell::RefCell;
use earshot::{DefaultPredictor, Detector};

struct State {
    detector: Detector,
    frame: [f32; 256],
}
thread_local! {
    static STATE: RefCell<State> = RefCell::new(State {
        detector: Detector::new(DefaultPredictor::new()), frame: [0.0; 256],
    });
}

// Each WebAssembly instance owns a detector. JS copies one 16 ms mono frame into
// this fixed allocation, then calls predict synchronously on the owning worker.
#[unsafe(no_mangle)]
pub extern "C" fn frame_pointer() -> usize {
    STATE.with(|state| state.borrow().frame.as_ptr() as usize)
}
#[unsafe(no_mangle)]
pub extern "C" fn reset() {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        state.detector.reset();
        state.frame.fill(0.0);
    });
}
#[unsafe(no_mangle)]
pub extern "C" fn predict(length: usize) -> f32 {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        if length != 256 || state.frame.iter().any(|x| !x.is_finite()) {
            return f32::NAN;
        }
        let State { detector, frame } = &mut *state;
        for sample in frame.iter_mut() { *sample = sample.clamp(-1.0, 1.0); }
        detector.predict_f32(frame)
    })
}
