use std::io::{self, Read};
use earshot::{DefaultPredictor, Detector};
fn main() {
    let mut bytes = Vec::new();
    io::stdin().read_to_end(&mut bytes).unwrap();
    let mut detector = Detector::new(DefaultPredictor::new());
    for chunk in bytes.chunks_exact(1024) {
        let samples: Vec<f32> = chunk.chunks_exact(4).map(|v| f32::from_le_bytes(v.try_into().unwrap())).collect();
        println!("{}", detector.predict_f32(&samples));
    }
}
