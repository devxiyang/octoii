//! Images as models and a person's view are given them: an image of any format read fitted within bounds — kept as it
//! is where it fits them, else resized and written again — on none of Siphon's other parts, as it is a computation on
//! bytes alone.
const fit = @import("image/fit.zig");
pub const Format = fit.Format;
pub const Formats = fit.Formats;
pub const Bounds = fit.Bounds;
pub const Size = fit.Size;
pub const Fitted = fit.Fitted;
pub const Error = fit.Error;
pub const fitted = fit.fitted;
pub const sizeWithin = fit.sizeWithin;

test {
    _ = fit;
}
