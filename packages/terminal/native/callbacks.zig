// Adapted from MIT-licensed code, MIT License, Copyright (c) 2026 T3 Tools Inc.; see THIRD_PARTY_NOTICES.
// Our changes: the render hold's callback, where a terminal that is a view answers nothing and hears no title.

//! The terminal's callbacks, as functions of WebAssembly that the terminal module's function table can hold: each hands
//! its arguments to the page's function of the same name. A page's own function cannot sit in another module's table.

extern "env" fn render_hold(terminal: u32, userdata: u32, held: bool) void;

export fn on_render_hold(terminal: u32, userdata: u32, held: bool) void {
    render_hold(terminal, userdata, held);
}
