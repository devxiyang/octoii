//! The shell's language read: a command line's simple commands as Bash reads them, by tree-sitter's grammar, or why no
//! reading knows them — on none of Siphon's other parts, as it is a computation on the line alone.
const parse_ = @import("shell/parse.zig");
pub const Word = parse_.Word;
pub const Assignment = parse_.Assignment;
pub const Redirection = parse_.Redirection;
pub const Command = parse_.Command;
pub const Unknowable = parse_.Unknowable;
pub const Parsed = parse_.Parsed;
pub const Error = parse_.Error;
pub const parse = parse_.parse;

test {
    _ = parse_;
}
