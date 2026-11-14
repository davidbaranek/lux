//! Where a new pin goes: after the pinned chats, as an order between 0 and 1 (`m.favourite`'s
//! `order`), so every device shows the pins alike.

/// The smallest gap between two orders kept apart; below it the pins are spread out again.
const SMALLEST_GAP: f64 = 1e-9;

/// How to pin a chat after the others.
#[derive(Clone, Debug, PartialEq)]
pub enum NewPin {
    /// The new pin takes this order; the others keep theirs.
    At(f64),
    /// The orders are used up (or some pin has none): the pinned chats take these orders, in
    /// their order, and the new pin takes `last`.
    Spread {
        /// The pinned chats' new orders, in their order.
        others: Vec<f64>,
        /// The new pin's order.
        last: f64,
    },
}

/// Where a pin goes after the chats pinned now, whose orders are `pinned` in pin order (`None`
/// for a pin another app made without one).
#[must_use]
pub fn after(pinned: &[Option<f64>]) -> NewPin {
    let finite: Option<Vec<f64>> = pinned
        .iter()
        .map(|order| order.filter(|order| order.is_finite() && (0.0..=1.0).contains(order)))
        .collect();
    let highest = finite.map(|orders| orders.into_iter().fold(0.0_f64, f64::max));
    match highest {
        Some(highest) if 1.0 - highest > SMALLEST_GAP => NewPin::At(f64::midpoint(highest, 1.0)),
        _ => {
            let count = pinned.len() + 2;
            #[allow(clippy::cast_precision_loss)] // a few pins, far below 2^52.
            let spread = |place: usize| place as f64 / count as f64;
            NewPin::Spread {
                others: (1..=pinned.len()).map(spread).collect(),
                last: spread(pinned.len() + 1),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{NewPin, after};

    #[test]
    fn the_first_pin_goes_in_the_middle() {
        assert_eq!(after(&[]), NewPin::At(0.5));
    }

    #[test]
    fn a_pin_goes_after_the_last() {
        assert_eq!(after(&[Some(0.5), Some(0.25)]), NewPin::At(0.75));
    }

    #[test]
    fn used_up_orders_or_pins_without_one_spread_out() {
        let NewPin::Spread { others, last } = after(&[Some(0.2), None]) else {
            panic!("not spread")
        };
        assert_eq!(others, [0.25, 0.5]);
        assert!((last - 0.75).abs() < f64::EPSILON);
        assert!(matches!(after(&[Some(1.0)]), NewPin::Spread { .. }));
    }
}
