use std::error::Error;
use std::thread;
use std::time::Duration;

use gilrs::{Axis, Button, Gilrs};

fn main() -> Result<(), Box<dyn Error>> {
    let seconds = std::env::args()
        .nth(1)
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(3);
    let mut gilrs = Gilrs::new()?;
    let started = std::time::Instant::now();
    let mut last = String::new();
    while started.elapsed() < Duration::from_secs(seconds) {
        while let Some(event) = gilrs.next_event() {
            println!("event {event:?}");
        }
        let mut now = Vec::new();
        for (id, pad) in gilrs.gamepads() {
            if !pad.is_connected() {
                continue;
            }
            let buttons: Vec<_> = [
                Button::South,
                Button::East,
                Button::West,
                Button::North,
                Button::Start,
                Button::Select,
                Button::DPadUp,
                Button::DPadDown,
                Button::DPadLeft,
                Button::DPadRight,
                Button::LeftThumb,
                Button::RightThumb,
            ]
            .into_iter()
            .filter(|button| pad.is_pressed(*button))
            .map(|button| format!("{button:?}"))
            .collect();
            now.push(format!(
                "{id:?} name={:?} vid={:?} pid={:?} buttons={buttons:?} lx={:.3} ly={:.3} rx={:.3} ry={:.3} lt={:.3} rt={:.3}",
                pad.name(),
                pad.vendor_id(),
                pad.product_id(),
                pad.value(Axis::LeftStickX),
                pad.value(Axis::LeftStickY),
                pad.value(Axis::RightStickX),
                pad.value(Axis::RightStickY),
                pad.value(Axis::LeftZ),
                pad.value(Axis::RightZ),
            ));
        }
        let text = now.join("\n");
        if text != last {
            println!("{text}");
            last = text;
        }
        thread::sleep(Duration::from_millis(20));
    }
    Ok(())
}
