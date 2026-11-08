//! tree-sitter's C API, as much of it as reading a shell line takes, and the Bash grammar it reads with.
pub const Parser = opaque {};
pub const Tree = opaque {};
pub const Language = opaque {};

/// A node of a tree, as tree-sitter passes one by value.
pub const Node = extern struct { context: [4]u32, id: ?*const anyopaque, tree: ?*const Tree };

pub extern fn ts_parser_new() ?*Parser;
pub extern fn ts_parser_delete(parser: *Parser) void;
pub extern fn ts_parser_set_language(parser: *Parser, language: *const Language) bool;
pub extern fn ts_parser_parse_string(parser: *Parser, old_tree: ?*const Tree, string: [*]const u8, length: u32) ?*Tree;
pub extern fn ts_tree_delete(tree: *Tree) void;
pub extern fn ts_tree_root_node(tree: *const Tree) Node;
pub extern fn ts_node_type(node: Node) [*:0]const u8;
pub extern fn ts_node_start_byte(node: Node) u32;
pub extern fn ts_node_end_byte(node: Node) u32;
pub extern fn ts_node_is_named(node: Node) bool;
pub extern fn ts_node_has_error(node: Node) bool;
pub extern fn ts_node_child_count(node: Node) u32;
pub extern fn ts_node_child(node: Node, index: u32) Node;
pub extern fn ts_node_field_name_for_child(node: Node, index: u32) ?[*:0]const u8;
pub extern fn tree_sitter_bash() *const Language;
