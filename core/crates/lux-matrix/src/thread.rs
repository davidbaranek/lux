//! The account as a thread's backend: its timelines, beside the saving and sending later it
//! does as an account.

use lux_core::ports::ThreadBackend;

use crate::{MatrixAccount, MatrixTimelines};

impl ThreadBackend for MatrixAccount {
    type Timelines = MatrixTimelines;

    fn timelines(&self) -> &MatrixTimelines {
        MatrixAccount::timelines(self)
    }
}
