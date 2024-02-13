const std = @import("std");
const os = @import("std").os;
const io = @import("std").io;

const VMIN = 6; // TODO: where is this?
const VTIME = 5; // TODO: where is this?
var orig_termios: os.termios = undefined;

const Cmd = enum {
    abort, //(C_g)
    accept_line, //(Newline or Return)
    backward_char, //(C_b)
    backward_delete_char, //(Rubout)
    backward_kill_line, //(C_x Rubout)
    backward_kill_word, //(M_DEL)
    backward_word, //(M_b)
    beginning_of_history, //(M_<)
    beginning_of_line, //(C_a)
    bracketed_paste_begin, //()
    call_last_kbd_macro, //(C_x e)
    capitalize_word, //(M_c)
    character_search, //(C_])
    character_search_backward, //(M_C_])
    clear_display, //(M_C_l)
    clear_screen, //(C_l)
    complete, //(TAB)
    copy_backward_word, //()
    copy_forward_word, //()
    copy_region_as_kill, //()
    delete_char, //(C_d)
    delete_char_or_list, //()
    delete_horizontal_space, //()
    digit_argument, //(M_0, M_1, … M__)
    do_lowercase_version, //(M_A, M_B, M_x, …)
    downcase_word, //(M_l)
    dump_functions, //()
    dump_macros, //()
    dump_variables, //()
    emacs_editing_mode, //(C_e)
    end_kbd_macro, //(C_x ))
    end_of_file, //(usually C_d)
    end_of_history, //(M_>)
    end_of_line, //(C_e)
    exchange_point_and_mark, //(C_x C_x)
    fetch_history, //()
    forward_backward_delete_char, //()
    forward_char, //(C_f)
    forward_search_history, //(C_s)
    forward_word, //(M_f)
    history_search_backward, //()
    history_search_forward, //()
    history_substring_search_backward, //()
    history_substring_search_forward, //()
    insert_comment, //(M_#)
    insert_completions, //(M_*)
    kill_line, //(C_k)
    kill_region, //()
    kill_whole_line, //()
    kill_word, //(M_d)
    menu_complete, //()
    menu_complete_backward, //()
    next_history, //(C_n)
    next_screen_line, //()
    non_incremental_forward_search_history, //(M_n)
    non_incremental_reverse_search_history, //(M_p)
    operate_and_get_next, //(C_o)
    overwrite_mode, //()
    possible_completions, //(M_?)
    prefix_meta, //(ESC)
    previous_history, //(C_p)
    previous_screen_line, //()
    print_last_kbd_macro, //()
    quoted_insert, //(C_q or C_v)
    re_read_init_file, //(C_x C_r)
    redraw_current_line, //()
    reverse_search_history, //(C_r)
    revert_line, //(M_r)
    self_insert, //(a, b, A, 1, !, …)
    set_mark, //(C_@)
    shell_transpose_words, //(M_C_t)
    skip_csi_sequence, //()
    start_kbd_macro, //(C_x ()
    tab_insert, //(M_TAB)
    tilde_expand, //(M_~)
    transpose_chars, //(C_t)
    transpose_words, //(M_t)
    undo, //(C__ or C_x C_u)
    universal_argument, //()
    unix_filename_rubout, //()
    unix_line_discard, //(C_u)
    unix_word_rubout, //(C_w)
    upcase_word, //(M_u)
    vi_editing_mode, //(M_C_j)
    yank, //(C_y)
    yank_last_arg, //(M_. or M__)
    yank_nth_arg, //(M_C_y)
    yank_pop, //(M_y)
    ctrl_c, //C_c
    no_op,
};

const ViMode = enum { insert, command };
const EditingModeType = enum { vi, emacs };
const EditingMode = union { vi: ViMode, emacs: u8 };

const NoLine = enum {
    CTRL_D,
    CTRL_C,
};

const ReadType = enum { line, no_line };
const Read = union(ReadType) {
    line: []u8,
    no_line: NoLine,
};

const InputType = enum { edit_more, read };

const Input = union(InputType) {
    edit_more: u8,
    read: Read,
};

const edit_more = Input{ .edit_more = 0 };

const Zigline = struct {
    // struct linenoiseState {
    //     int in_completion;  /* The user pressed TAB and we are now in completion
    //                          * mode, so input is handled by completeLine(). */
    //     size_t completion_idx; /* Index of next completion to propose. */
    //-----int ifd;            /* Terminal stdin file descriptor. */
    //-----int ofd;            /* Terminal stdout file descriptor. */
    //-----char *buf;          /* Edited line buffer. */
    //-----size_t buflen;      /* Edited line buffer size. */
    //     const char *prompt; /* Prompt to display. */
    //     size_t plen;        /* Prompt length. */
    //-----pos;         /* Current cursor position. */
    //     size_t oldpos;      /* Previous refresh cursor position. */
    //-----len;         /* Current edited line length. */
    //     size_t cols;        /* Number of columns in terminal. */
    //     size_t oldrows;     /* Rows used by last refrehsed line (multiline mode) */
    //     int history_index;  /* The history index we are currently editing. */
    // };

    pub fn init(in: std.fs.File, out: std.fs.File, allocator: std.mem.Allocator) !Zigline {
        return Zigline{
            .in = in,
            .out = out,
            .alloc = allocator,
            .lbuf = std.ArrayList(u8).init(allocator),
            .tmpbuf = std.ArrayList(u8).init(allocator),
            .hist = std.ArrayList([]const u8).init(allocator),
            .histix = 0,
            .pos = 0,
            .rawmode = false,
        };
    }

    pub fn deinit(self: *Zigline) void {
        _ = &self;
        for (self.hist.items) |ln| self.alloc.free(ln);
        self.hist.deinit();
        self.lbuf.deinit();
        self.disableRawMode();
    }

    in: std.fs.File,
    out: std.fs.File,
    alloc: std.mem.Allocator,
    lbuf: std.ArrayList(u8),
    tmpbuf: std.ArrayList(u8),
    hist: std.ArrayList([]const u8),
    histix: usize,
    pos: usize,
    rawmode: bool,

    fn readchar(self: *Zigline) !u8 {
        var cbuf: [1]u8 = undefined;
        const read = try self.in.reader().read(&cbuf);
        if (read < 1) {
            return Error.Read;
        }
        return cbuf[0];
    }

    fn selfInsert(self: *Zigline, c: u8) !Input {
        var l = self.lbuf.items.len;
        try self.lbuf.append(c);
        if (self.pos < l) {
            while (self.pos < l) : (l -= 1) {
                self.lbuf.items[l] = self.lbuf.items[l - 1];
            }
            self.lbuf.items[self.pos] = c;
        }
        self.pos += 1;
        return edit_more;
    }

    fn refreshLine(self: *Zigline, writer: anytype) !void {
        //TODO: maskmode  while (len--) abAppend(&ab,"*",1);
        if (self.pos > 0) {
            try std.fmt.format(writer, "\r{s}\x1b[0K\r\x1b[{d}C", .{ self.lbuf.items, self.pos });
        } else {
            try std.fmt.format(writer, "\r{s}\x1b[0K\r", .{self.lbuf.items});
        }
    }

    fn deleteChar(self: *Zigline) !Input {
        const l = self.lbuf.items.len;
        if (l > 0 and self.pos < l) {
            const from: usize = self.pos;
            const to: usize = self.lbuf.items.len - 1;
            for (from..to) |i| {
                self.lbuf.items[i] = self.lbuf.items[i + 1];
            }
            _ = self.lbuf.pop();
            if (self.pos > l) {
                self.pos -= 1;
            }
        }
        return edit_more;
    }

    fn backwardDeleteChar(self: *Zigline) !Input {
        if (self.pos > 0 and self.lbuf.items.len > 0) {
            const from: usize = self.pos - 1;
            const to: usize = self.lbuf.items.len - 1;
            for (from..to) |i| {
                self.lbuf.items[i] = self.lbuf.items[i + 1];
            }
            _ = self.lbuf.pop();
            self.pos -= 1;
        }
        return edit_more;
    }

    fn clearScreen(self: *Zigline, writer: anytype) !Input {
        _ = &self;
        const written = try writer.write("\x1b[H\x1b[2J");
        if (written != 7) {
            return Error.Write;
        }
        //try stdout_writer.write("\x1b[H\x1b[2J", 7);
        return edit_more;
    }

    fn transposeChars(self: *Zigline) Input {
        if (self.lbuf.items.len > 1 and self.pos > 0) {
            const i = if (self.pos < self.lbuf.items.len) self.pos else self.pos - 1;
            const tmp = self.lbuf.items[i - 1];
            self.lbuf.items[i - 1] = self.lbuf.items[i];
            self.lbuf.items[i] = tmp;
        }
        return edit_more;
    }

    pub fn readline(self: *Zigline) !Read {
        try self.enableRawMode();
        defer self.disableRawMode();
        while (true) {
            const read = try self.readInput();
            switch (read) {
                .edit_more => continue,
                .read => |r| return r,
            }
        }
    }

    // fn inputToCmdVi(self: *Zigline, mode: ViMode, c: u8) !Cmd { TODO

    fn keyActionToCmdEmacs(self: *Zigline, c: u8) !Cmd {
        return switch (c) {
            @intFromEnum(KeyAction.BACKSPACE) => Cmd.backward_delete_char,
            @intFromEnum(KeyAction.CTRL_A) => Cmd.beginning_of_line,
            @intFromEnum(KeyAction.CTRL_B) => Cmd.backward_char,
            @intFromEnum(KeyAction.CTRL_C) => Cmd.ctrl_c,
            @intFromEnum(KeyAction.CTRL_D) => if (self.lbuf.items.len == 0) Cmd.end_of_file else Cmd.delete_char,
            @intFromEnum(KeyAction.CTRL_E) => Cmd.end_of_line,
            @intFromEnum(KeyAction.CTRL_F) => Cmd.forward_char,
            @intFromEnum(KeyAction.CTRL_H) => Cmd.backward_delete_char,
            //@intFromEnum(KeyAction.TAB) => ,
            @intFromEnum(KeyAction.CTRL_K) => Cmd.kill_line,
            @intFromEnum(KeyAction.CTRL_L) => Cmd.clear_screen,
            @intFromEnum(KeyAction.ENTER) => Cmd.accept_line,
            @intFromEnum(KeyAction.CTRL_N) => Cmd.next_history,
            @intFromEnum(KeyAction.CTRL_P) => Cmd.previous_history,
            @intFromEnum(KeyAction.CTRL_T) => Cmd.transpose_chars,
            @intFromEnum(KeyAction.CTRL_U) => Cmd.unix_line_discard,
            @intFromEnum(KeyAction.CTRL_W) => Cmd.unix_word_rubout,
            @intFromEnum(KeyAction.ESC) => switch (try self.readchar()) {
                @intFromEnum(KeyAction.ESC) => Cmd.no_op,
                'f', 'F' => Cmd.forward_word,
                'b', 'B' => Cmd.backward_word,
                // 91
                '[' => switch (try self.readchar()) {
                    // 51
                    '3' => switch (try self.readchar()) {
                        '~' => Cmd.delete_char,
                        else => Error.NotImpl,
                    },
                    'A' => Cmd.previous_history,
                    'B' => Cmd.next_history,
                    'C' => Cmd.forward_char,
                    'D' => Cmd.backward_char,
                    else => Error.NotImpl,
                },
                else => Error.NotImpl,
            },
            else => Cmd.self_insert,
        };
    }

    pub fn readCmd(self: *Zigline, cmd: Cmd, c: u8) !Input {
        const lblen = self.lbuf.items.len;
        return blk: {
            break :blk switch (cmd) {
                Cmd.abort => Error.NotImpl,
                Cmd.accept_line => {
                    const line = try self.alloc.dupe(u8, self.lbuf.items);
                    if (lblen > 0) {
                        self.lbuf.clearRetainingCapacity();
                        self.pos = 0;
                    }
                    break :blk Input{ .read = Read{ .line = line } };
                },
                Cmd.backward_char => {
                    if (self.pos > 0) {
                        self.pos -= 1;
                    }
                    break :blk edit_more;
                },
                Cmd.backward_delete_char => try self.backwardDeleteChar(),
                Cmd.backward_kill_line => Error.NotImpl,
                Cmd.backward_kill_word => Error.NotImpl,
                Cmd.backward_word => {
                    const l = self.lbuf.items.len;
                    if (l > 0) {
                        if (self.pos >= self.lbuf.items.len) {
                            self.pos -= 1;
                        }
                        while (self.pos > 0 and self.lbuf.items[self.pos] == ' ') {
                            self.pos -= 1;
                        }
                        while (self.pos > 0 and self.lbuf.items[self.pos] != ' ') {
                            self.pos -= 1;
                        }
                    }
                    break :blk edit_more;
                },
                Cmd.beginning_of_history => Error.NotImpl,
                Cmd.beginning_of_line => {
                    self.pos = 0;
                    break :blk edit_more;
                },
                Cmd.bracketed_paste_begin => Error.NotImpl,
                Cmd.call_last_kbd_macro => Error.NotImpl,
                Cmd.capitalize_word => Error.NotImpl,
                Cmd.character_search => Error.NotImpl,
                Cmd.character_search_backward => Error.NotImpl,
                Cmd.clear_display => Error.NotImpl,
                Cmd.clear_screen => Error.NotImpl, //try self.clearScreen(),
                Cmd.complete => Error.NotImpl,
                Cmd.copy_backward_word => Error.NotImpl,
                Cmd.copy_forward_word => Error.NotImpl,
                Cmd.copy_region_as_kill => Error.NotImpl,
                Cmd.delete_char => try self.deleteChar(),
                Cmd.delete_char_or_list => Error.NotImpl,
                Cmd.delete_horizontal_space => Error.NotImpl,
                Cmd.digit_argument => Error.NotImpl,
                Cmd.do_lowercase_version => Error.NotImpl,
                Cmd.downcase_word => Error.NotImpl,
                Cmd.dump_functions => Error.NotImpl,
                Cmd.dump_macros => Error.NotImpl,
                Cmd.dump_variables => Error.NotImpl,
                Cmd.emacs_editing_mode => Error.NotImpl,
                Cmd.end_kbd_macro => Error.NotImpl,
                Cmd.end_of_file => Input{ .read = Read{ .no_line = NoLine.CTRL_D } },
                Cmd.end_of_history => Error.NotImpl,
                Cmd.end_of_line => {
                    self.pos = lblen;
                    break :blk edit_more;
                },
                Cmd.exchange_point_and_mark => Error.NotImpl,
                Cmd.fetch_history => Error.NotImpl,
                Cmd.forward_backward_delete_char => Error.NotImpl,
                Cmd.forward_char => {
                    self.pos = if (self.pos < lblen) self.pos +| 1 else lblen;
                    break :blk edit_more;
                },
                Cmd.forward_search_history => Error.NotImpl,
                Cmd.forward_word => {
                    while (self.pos < self.lbuf.items.len and self.lbuf.items[self.pos] == ' ') {
                        self.pos += 1;
                    }
                    while (self.pos < self.lbuf.items.len and self.lbuf.items[self.pos] != ' ') {
                        self.pos += 1;
                    }
                    break :blk edit_more;
                },
                Cmd.history_search_backward => Error.NotImpl,
                Cmd.history_search_forward => Error.NotImpl,
                Cmd.history_substring_search_backward => Error.NotImpl,
                Cmd.history_substring_search_forward => Error.NotImpl,
                Cmd.insert_comment => Error.NotImpl,
                Cmd.insert_completions => Error.NotImpl,
                Cmd.kill_line => Error.NotImpl,
                Cmd.kill_region => Error.NotImpl,
                Cmd.kill_whole_line => Error.NotImpl,
                Cmd.kill_word => Error.NotImpl,
                Cmd.menu_complete => Error.NotImpl,
                Cmd.menu_complete_backward => Error.NotImpl,
                Cmd.next_history => {
                    if (self.histix > 0) {
                        if (self.histix == 1) {
                            self.lbuf = std.ArrayList(u8).fromOwnedSlice(self.alloc, try self.tmpbuf.toOwnedSlice());
                        } else {
                            self.lbuf.clearRetainingCapacity();
                            try self.lbuf.appendSlice(self.hist.items[self.hist.items.len - self.histix + 1]);
                        }
                        self.histix -= 1;
                        self.pos = self.lbuf.items.len;
                    }
                    break :blk edit_more;
                },
                Cmd.next_screen_line => Error.NotImpl,
                Cmd.non_incremental_forward_search_history => Error.NotImpl,
                Cmd.non_incremental_reverse_search_history => Error.NotImpl,
                Cmd.operate_and_get_next => Error.NotImpl,
                Cmd.overwrite_mode => Error.NotImpl,
                Cmd.possible_completions => Error.NotImpl,
                Cmd.prefix_meta => Error.NotImpl,
                Cmd.previous_history => {
                    const hlen = self.hist.items.len;
                    if (hlen > 0 and self.histix < hlen) {
                        if (self.histix == 0) {
                            self.tmpbuf = std.ArrayList(u8).fromOwnedSlice(self.alloc, try self.lbuf.toOwnedSlice());
                        }
                        self.lbuf.clearRetainingCapacity();
                        try self.lbuf.appendSlice(self.hist.items[self.hist.items.len - 1 - self.histix]);
                        self.histix = self.histix +| 1;
                        self.pos = self.lbuf.items.len;
                    }
                    break :blk edit_more;
                },
                Cmd.previous_screen_line => Error.NotImpl,
                Cmd.print_last_kbd_macro => Error.NotImpl,
                Cmd.quoted_insert => Error.NotImpl,
                Cmd.re_read_init_file => Error.NotImpl,
                Cmd.redraw_current_line => Error.NotImpl,
                Cmd.reverse_search_history => Error.NotImpl,
                Cmd.revert_line => Error.NotImpl,
                Cmd.self_insert => try self.selfInsert(c),
                Cmd.set_mark => Error.NotImpl,
                Cmd.shell_transpose_words => Error.NotImpl,
                Cmd.skip_csi_sequence => Error.NotImpl,
                Cmd.start_kbd_macro => Error.NotImpl,
                Cmd.tab_insert => Error.NotImpl,
                Cmd.tilde_expand => Error.NotImpl,
                Cmd.transpose_chars => self.transposeChars(),
                Cmd.transpose_words => Error.NotImpl,
                Cmd.undo => Error.NotImpl,
                Cmd.universal_argument => Error.NotImpl,
                Cmd.unix_filename_rubout => Error.NotImpl,
                Cmd.unix_line_discard => Error.NotImpl,
                Cmd.unix_word_rubout => Error.NotImpl,
                Cmd.upcase_word => Error.NotImpl,
                Cmd.vi_editing_mode => Error.NotImpl,
                Cmd.yank => Error.NotImpl,
                Cmd.yank_last_arg => Error.NotImpl,
                Cmd.yank_nth_arg => Error.NotImpl,
                Cmd.yank_pop => Error.NotImpl,
                Cmd.ctrl_c => Input{ .read = Read{ .no_line = NoLine.CTRL_C } },
                Cmd.no_op => {
                    break :blk edit_more;
                },
            };
        };
    }

    pub fn readInput(self: *Zigline) !Input {
        const c: u8 = try self.readchar();
        const cmd = try self.keyActionToCmdEmacs(c);
        const input = try self.readCmd(cmd, c);
        var bw = std.io.bufferedWriter(self.out.writer());
        const stdout_writer = bw.writer();
        try self.refreshLine(stdout_writer);
        try bw.flush(); // don't forget to flush!
        self.tmpbuf.clearRetainingCapacity();
        return input;
    }

    pub fn addHistory(self: *Zigline, line: []u8) !void {
        try self.hist.append(line);
    }

    pub fn enableRawMode(self: *Zigline) !void {
        //obtain fd from out file
        if (!self.rawmode) {
            try _enableRawMode(os.STDIN_FILENO);
            self.rawmode = true;
        }
    }

    pub fn disableRawMode(self: *Zigline) void {
        if (self.rawmode) {
            //TODO: obtain fd from out file
            const res = os.tcsetattr(os.STDIN_FILENO, os.TCSA.FLUSH, orig_termios);
            if (res) {
                self.rawmode = false;
            } else |err| {
                _ = &err;
                std.debug.print("Error returned by tcssetattr", .{});
            }
        }
    }
};

const KeyAction = enum(u8) {
    KEY_NULL = 0,
    CTRL_A = 1,
    CTRL_B = 2,
    CTRL_C = 3,
    CTRL_D = 4,
    CTRL_E = 5,
    CTRL_F = 6,
    CTRL_H = 8,
    TAB = 9,
    CTRL_J = 10,
    CTRL_K = 11,
    CTRL_L = 12,
    ENTER = 13,
    CTRL_N = 14,
    CTRL_O = 15,
    CTRL_P = 16,
    CTRL_Q = 17,
    CTRL_R = 18,
    CTRL_S = 19,
    CTRL_T = 20,
    CTRL_U = 21,
    CTRL_V = 22,
    CTRL_W = 23,
    CTRL_X = 24,
    CTRL_Y = 25,
    ESC = 27,
    BACKSPACE = 127,
};

fn _enableRawMode(fd: i32) !void {
    var raw: os.termios = undefined;

    if (!os.isatty(os.STDIN_FILENO)) { //TODO: raise
        return;
    }

    orig_termios = try os.tcgetattr(fd);

    raw = orig_termios; // modify the original mode
    // input modes: no break, no CR to NL, no parity check, no strip char,
    // no start/stop output control.
    raw.iflag &= ~(os.linux.BRKINT | os.linux.ICRNL | os.linux.INPCK | os.linux.ISTRIP | os.linux.IXON);
    // output modes - disable post processing
    raw.oflag &= ~(os.linux.OPOST);
    // control modes - set 8 bit chars
    raw.cflag |= (os.linux.CS8);
    // local modes - choing off, canonical off, no extended functions, no
    // signal chars (^Z,^C)
    raw.lflag &= ~(os.linux.ECHO | os.linux.ICANON | os.linux.IEXTEN | os.linux.ISIG);
    // control chars - set return condition: min number of bytes and
    // timer. We want read to return every single byte, without timeout.
    raw.cc[VMIN] = 1;
    raw.cc[VTIME] = 0; // 1 byte, no timer

    // put terminal in raw mode after flushing
    try os.tcsetattr(fd, os.TCSA.FLUSH, raw);
}

const Error = error{ Read, Write, NotImpl };

pub fn main() !void {
    //allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    //stdout
    const stdout = std.io.getStdOut();
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();
    //stdin
    const stdin = std.io.getStdIn(); //.reader();

    try stdout_writer.print("Zigline :) Exit with C-d\n", .{});
    try bw.flush(); // don't forget to flush!

    var zigline = try Zigline.init(stdin, stdout, allocator);
    defer zigline.deinit();
    while (true) {
        const read = try zigline.readline();
        switch (read) {
            .line => |ln| {
                std.debug.print("{s}\n", .{ln});
                if (ln.len > 0) {
                    try zigline.addHistory(ln);
                } else {
                    zigline.alloc.free(ln);
                }
            },
            .no_line => |nol| switch (nol) {
                NoLine.CTRL_C => {
                    std.debug.print("^C\n", .{});
                },
                NoLine.CTRL_D => break,
            },
        }
    }

    for (zigline.hist.items, 1..) |ln, i| {
        std.debug.print("line {d}: `{s}'\n", .{ i, ln });
    }
}
