const std = @import("std");
const os = @import("std").os;
const io = @import("std").io;
const posix = @import("std").posix;

const Error = error{ Read, Write, NotImpl, IndexError };

var orig_termios: posix.termios = undefined;

const Cmd = enum {
    abort, //(C-g)
    accept_line, //(Newline or Return)
    backward_char, //(C-b)
    backward_delete_char, //(Rubout)
    backward_kill_line, //(C-x Rubout)
    backward_kill_word, //(M-DEL)
    backward_word, //(M-b)
    beginning_of_history, //(M-<)
    beginning_of_line, //(C-a)
    bracketed_paste_begin, //()
    call_last_kbd_macro, //(C-x e)
    capitalize_word, //(M-c)
    character_search, //(C-])
    character_search_backward, //(M-C-])
    clear_display, //(M-C-l)
    clear_screen, //(C-l)
    complete, //(TAB)
    copy_backward_word, //()
    copy_forward_word, //()
    copy_region_as_kill, //()
    delete_char, //(C-d)
    delete_char_or_list, //()
    delete_horizontal_space, //()
    digit_argument, //(M-0, M-1, … M-_)
    do_lowercase_version, //(M-A, M-B, M-x, …)
    downcase_word, //(M-l)
    dump_functions, //()
    dump_macros, //()
    dump_variables, //()
    emacs_editing_mode, //(C-e)
    end_kbd_macro, //(C-x ))
    end_of_file, //(usually C-d)
    end_of_history, //(M->)
    end_of_line, //(C-e)
    exchange_point_and_mark, //(C-x C-x)
    fetch_history, //()
    forward_backward_delete_char, //()
    forward_char, //(C-f)
    forward_search_history, //(C-s)
    forward_word, //(M-f)
    history_search_backward, //()
    history_search_forward, //()
    history_substring_search_backward, //()
    history_substring_search_forward, //()
    insert_comment, //(M-#)
    insert_completions, //(M-*)
    kill_line, //(C-k)
    kill_region, //()
    kill_whole_line, //()
    kill_word, //(M-d)
    menu_complete, //()
    menu_complete_backward, //()
    next_history, //(C-n)
    next_screen_line, //()
    non_incremental_forward_search_history, //(M-n)
    non_incremental_reverse_search_history, //(M-p)
    operate_and_get_next, //(C-o)
    overwrite_mode, //()
    possible_completions, //(M-?)
    prefix_meta, //(ESC)
    previous_history, //(C-p)
    previous_screen_line, //()
    print_last_kbd_macro, //()
    quoted_insert, //(C-q or C-v)
    re_read_init_file, //(C-x C-r)
    redraw_current_line, //()
    reverse_search_history, //(C-r)
    revert_line, //(M-r)
    self_insert, //(a, b, A, 1, !, …)
    set_mark, //(C-@)
    shell_transpose_words, //(M-C-t)
    skip_csi_sequence, //()
    start_kbd_macro, //(C-x ()
    tab_insert, //(M-TAB)
    tilde_expand, //(M-~)
    transpose_chars, //(C-t)
    transpose_words, //(M-t)
    undo, //(C-_ or C-x C-u)
    universal_argument, //()
    unix_filename_rubout, //()
    unix_line_discard, //(C-u)
    unix_word_rubout, //(C-w)
    upcase_word, //(M-u)
    vi_editing_mode, //(M-C-j)
    yank, //(C-y)
    yank_last_arg, //(M-. or M-_)
    yank_nth_arg, //(M-C-y)
    yank_pop, //(M-y)
    ctrl_c, //C-c
    no_op,
};

const ViMode = enum { insert, command };
const EditingModeType = enum { vi, emacs };
const EditingMode = union { vi: ViMode, emacs: u8 };

pub const NoLine = enum {
    CTRL_D,
    CTRL_C, //TODO?: attach line
};

const ReadType = enum { line, no_line };
pub const Read = union(ReadType) {
    line: []u8,
    no_line: NoLine,
};

const InputType = enum { edit_more, clear_screen, read };

const Input = union(InputType) {
    edit_more: u8,
    clear_screen: u8,
    read: Read,
};

const edit_more = Input{ .edit_more = 0 };
const clear_screen = Input{ .clear_screen = 0 };

pub const Zigline = struct {
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
    //-----int history_index;  /* The history index we are currently editing. */
    // };

    pub fn init(in: std.fs.File, out: std.fs.File, allocator: std.mem.Allocator) !Zigline {
        return Zigline{
            .in = in,
            .out = out,
            .alloc = allocator,
            .lbuf = std.ArrayList(u8).init(allocator),
            .tmpbuf = std.ArrayList(u8).init(allocator),
            .hist = std.ArrayList([]const u8).init(allocator),
            .hist_ptr = 0,
            .pos = 0,
            .rawmode = false,
            .kill_ring = std.ArrayList([]const u8).init(allocator),
            .kill_ring_ix = 0,
            .last_cmd = Cmd.no_op,
        };
    }

    pub fn deinit(self: *Zigline) void {
        for (self.hist.items) |ln| self.alloc.free(ln);
        for (self.kill_ring.items) |item| self.alloc.free(item);
        self.hist.deinit();
        self.lbuf.deinit();
        self.tmpbuf.deinit();
        self.disableRawMode();
    }

    in: std.fs.File,
    out: std.fs.File,
    alloc: std.mem.Allocator,
    lbuf: std.ArrayList(u8),
    tmpbuf: std.ArrayList(u8),
    hist: std.ArrayList([]const u8),
    hist_ptr: usize,
    pos: usize,
    rawmode: bool,
    kill_ring: std.ArrayList([]const u8),
    kill_ring_ix: usize,
    last_cmd: Cmd,

    pub fn readline(self: *Zigline) !Read {
        try self.enableRawMode();
        defer self.disableRawMode();
        self.tmpbuf.clearRetainingCapacity();
        self.resetLbuf();
        var bw = std.io.bufferedWriter(self.out.writer());
        const stdout_writer = bw.writer();
        while (true) {
            const read = try self.readInput();
            switch (read) {
                .edit_more => {
                    try self.refreshLine(stdout_writer);
                    try bw.flush();
                },
                .clear_screen => {
                    try self.clearScreen(stdout_writer);
                    try self.refreshLine(stdout_writer);
                    try bw.flush();
                },
                .read => |r| {
                    try std.fmt.format(stdout_writer, "\r\x1b[0K\r", .{});
                    try bw.flush();
                    return r;
                },
            }
        }
    }

    pub fn addHistory(self: *Zigline, line: []u8) !void {
        if (self.hist.items.len == 0 or !std.mem.eql(u8, self.hist.getLast(), line)) {
            try self.hist.append(line);
        }
    }

    /// Commands
    //

    fn backwardDeleteChar(self: *Zigline) !Input {
        if (self.pos > 0 and self.lbuf.items.len > 0) {
            try moveMemBackwards(self.lbuf.items, self.pos, self.pos - 1);
            _ = self.lbuf.pop();
            self.pos -= 1;
        }
        return edit_more;
    }

    fn backwardKillLine(self: *Zigline) !Input {
        if (self.pos > 0) {
            try self.cloneToKillRing(self.lbuf.items[0..self.pos]);
            try moveMemBackwards(self.lbuf.items, self.pos, 0);
            self.lbuf.shrinkRetainingCapacity(self.lbuf.items.len - self.pos);
            self.pos = 0;
        }
        return edit_more;
    }

    fn backwardKillWord(self: *Zigline) !Input {
        if (self.lbuf.items.len > 0) {
            const old_pos = self.pos;
            self.pos = getBackwardWordIndex(self.lbuf.items, self.pos);
            try self.cloneToKillRing(self.lbuf.items[self.pos..old_pos]);
            try moveMemBackwards(self.lbuf.items, old_pos, self.pos);
            self.lbuf.shrinkRetainingCapacity(self.lbuf.items.len - (old_pos - self.pos));
        }
        return edit_more;
    }

    fn backwardWord(self: *Zigline) !Input {
        self.pos = getBackwardWordIndex(self.lbuf.items, self.pos);
        return edit_more;
    }

    fn beginningOfHistory(self: *Zigline) !Input {
        const hlen = self.hist.items.len;
        if (hlen > 0) {
            if (self.hist_ptr == 0) {
                self.tmpbuf = std.ArrayList(u8).fromOwnedSlice(self.alloc, try self.lbuf.toOwnedSlice());
            } else {
                self.lbuf.clearRetainingCapacity();
            }
            self.hist_ptr = hlen - 1;
            try self.lbuf.appendSlice(self.hist.items[hlen - 1 - self.hist_ptr]);
            self.pos = self.lbuf.items.len;
        }
        return edit_more;
    }

    fn clearScreen(self: *Zigline, writer: anytype) !void {
        _ = &self;
        const written = try writer.write("\x1b[H\x1b[2J");
        if (written != 7) {
            return Error.Write;
        }
    }

    fn deleteChar(self: *Zigline) !Input {
        const l = self.lbuf.items.len;
        if (l > 0 and self.pos < l) {
            try moveMemBackwards(self.lbuf.items, self.pos + 1, self.pos);
            _ = self.lbuf.pop();
            if (self.pos > l) {
                self.pos -= 1;
            }
        }
        return edit_more;
    }

    fn endOfHistory(self: *Zigline) !Input {
        const hlen = self.hist.items.len;
        if (hlen > 0 and self.hist_ptr > 0) {
            self.lbuf.clearRetainingCapacity();
            self.hist_ptr = 0;
            if (self.tmpbuf.items.len > 0) {
                self.lbuf = std.ArrayList(u8).fromOwnedSlice(self.alloc, try self.tmpbuf.toOwnedSlice());
            } else {
                try self.lbuf.appendSlice(self.hist.items[hlen - 1 - self.hist_ptr]);
            }
            self.pos = self.lbuf.items.len;
        }
        return edit_more;
    }

    fn forwardWord(self: *Zigline) !Input {
        self.pos = getForwardWordIndex(self.lbuf.items, self.pos);
        return edit_more;
    }

    fn killLine(self: *Zigline) !Input {
        try self.cloneToKillRing(self.lbuf.items);
        self.lbuf.shrinkRetainingCapacity(self.pos);
        return edit_more;
    }

    fn killWord(self: *Zigline) !Input {
        if (self.lbuf.items.len > self.pos) {
            const new_pos = getForwardWordIndex(self.lbuf.items, self.pos);
            try self.cloneToKillRing(self.lbuf.items[self.pos..new_pos]);
            try moveMemBackwards(self.lbuf.items, new_pos, self.pos);
            const len_delta = new_pos - self.pos;
            self.lbuf.shrinkRetainingCapacity(self.lbuf.items.len - len_delta);
        }
        return edit_more;
    }

    fn nextHistory(self: *Zigline) !Input {
        if (self.hist_ptr > 0) { // else: end of history
            if (self.hist_ptr == 1) { // moving back to end
                self.lbuf = std.ArrayList(u8).fromOwnedSlice(self.alloc, try self.tmpbuf.toOwnedSlice());
            } else {
                self.lbuf.clearRetainingCapacity();
                try self.lbuf.appendSlice(self.hist.items[self.hist.items.len - self.hist_ptr + 1]);
            }
            self.hist_ptr -= 1;
            self.pos = self.lbuf.items.len;
        }
        return edit_more;
    }

    fn previousHistory(self: *Zigline) !Input {
        const hlen = self.hist.items.len;
        if (hlen > 0 and self.hist_ptr < hlen) {
            if (self.hist_ptr == 0) {
                self.tmpbuf = std.ArrayList(u8).fromOwnedSlice(self.alloc, try self.lbuf.toOwnedSlice());
            } else {
                self.lbuf.clearRetainingCapacity();
            }
            try self.lbuf.appendSlice(self.hist.items[self.hist.items.len - 1 - self.hist_ptr]);
            self.hist_ptr = self.hist_ptr + 1;
            self.pos = self.lbuf.items.len;
        }
        return edit_more;
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

    fn transposeChars(self: *Zigline) Input {
        if (self.lbuf.items.len > 1 and self.pos > 0) {
            const i = if (self.pos < self.lbuf.items.len) self.pos else self.pos - 1;
            const tmp = self.lbuf.items[i - 1];
            self.lbuf.items[i - 1] = self.lbuf.items[i];
            self.lbuf.items[i] = tmp;
        }
        return edit_more;
    }

    fn unixWordRobout(self: *Zigline) !Input {
        if (self.lbuf.items.len > 0) {
            const old_pos = self.pos;
            self.pos = getBackwardLargeWordIndex(self.lbuf.items, self.pos);
            try self.cloneToKillRing(self.lbuf.items[self.pos..old_pos]);
            try moveMemBackwards(self.lbuf.items, old_pos, self.pos);
            self.lbuf.shrinkRetainingCapacity(self.lbuf.items.len - (old_pos - self.pos));
        }
        return edit_more;
    }

    fn yank(self: *Zigline) !Input {
        if (self.kill_ring.items.len > 0) {
            const text = self.getKillRingTop();
            try self.lbuf.insertSlice(self.pos, text);
        }
        return edit_more;
    }

    fn yankPop(self: *Zigline) !Input {
        if ((self.last_cmd == Cmd.yank or self.last_cmd == Cmd.yank_pop) and self.kill_ring.items.len > 1) {
            const prev_yank_len = self.getKillRingTop().len;
            self.kill_ring_ix = (self.kill_ring_ix + 1) % self.kill_ring.items.len;
            const text = self.getKillRingTop();
            const l = if ((prev_yank_len + self.pos) < self.lbuf.items.len) prev_yank_len else self.lbuf.items.len - self.pos;
            try self.lbuf.replaceRange(self.pos, l, text);
        }
        return edit_more;
    }

    // End of Commands

    /// Utils
    //

    fn getKillRingTop(self: *Zigline) []const u8 {
        return self.kill_ring.items[self.kill_ring.items.len - 1 - self.kill_ring_ix];
    }

    // End of Utils

    fn resetLbuf(self: *Zigline) void {
        if (self.lbuf.items.len > 0) {
            self.lbuf.clearRetainingCapacity();
            self.pos = 0;
        }
    }

    // fn inputToCmdVi(self: *Zigline, mode: ViMode, c: u8) !Cmd { TODO!

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
            @intFromEnum(KeyAction.CTRL_X) => switch (try self.readchar()) {
                @intFromEnum(KeyAction.BACKSPACE) => Cmd.backward_kill_line,
                @intFromEnum(KeyAction.CTRL_G) => Cmd.abort,
                else => Error.NotImpl,
            },
            @intFromEnum(KeyAction.CTRL_Y) => Cmd.yank,
            @intFromEnum(KeyAction.ESC) => switch (try self.readchar()) {
                @intFromEnum(KeyAction.ESC) => Cmd.no_op,
                'b', 'B' => Cmd.backward_word,
                'd', 'D' => Cmd.kill_word,
                'f', 'F' => Cmd.forward_word,
                'y', 'Y' => if (self.last_cmd == Cmd.yank_pop or self.last_cmd == Cmd.yank) Cmd.yank_pop else Cmd.no_op,
                '<' => Cmd.beginning_of_history,
                '>' => Cmd.end_of_history,
                @intFromEnum(KeyAction.BACKSPACE) => Cmd.backward_kill_word,

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

    fn readCmd(self: *Zigline, cmd: Cmd, c: u8) !Input {
        const lblen = self.lbuf.items.len;
        return blk: {
            break :blk switch (cmd) {
                Cmd.abort => edit_more,
                Cmd.accept_line => {
                    // lbuf need to be valid until refreshLine
                    const line = try self.alloc.dupe(u8, self.lbuf.items);
                    break :blk Input{ .read = Read{ .line = line } };
                },
                Cmd.backward_char => {
                    if (self.pos > 0) {
                        self.pos -= 1;
                    }
                    break :blk edit_more;
                },
                Cmd.backward_delete_char => try self.backwardDeleteChar(),
                Cmd.backward_kill_line => try self.backwardKillLine(),
                Cmd.backward_kill_word => self.backwardKillWord(),
                Cmd.backward_word => self.backwardWord(),
                Cmd.beginning_of_history => try self.beginningOfHistory(),
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
                Cmd.clear_screen => return clear_screen,
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
                Cmd.end_of_history => try self.endOfHistory(),
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
                Cmd.forward_word => self.forwardWord(),
                Cmd.history_search_backward => Error.NotImpl,
                Cmd.history_search_forward => Error.NotImpl,
                Cmd.history_substring_search_backward => Error.NotImpl,
                Cmd.history_substring_search_forward => Error.NotImpl,
                Cmd.insert_comment => Error.NotImpl,
                Cmd.insert_completions => Error.NotImpl,
                Cmd.kill_line => self.killLine(),
                Cmd.kill_region => Error.NotImpl,
                Cmd.kill_whole_line => Error.NotImpl,
                Cmd.kill_word => self.killWord(),
                Cmd.menu_complete => Error.NotImpl,
                Cmd.menu_complete_backward => Error.NotImpl,
                Cmd.next_history => self.nextHistory(),
                Cmd.next_screen_line => Error.NotImpl,
                Cmd.non_incremental_forward_search_history => Error.NotImpl,
                Cmd.non_incremental_reverse_search_history => Error.NotImpl,
                Cmd.operate_and_get_next => Error.NotImpl,
                Cmd.overwrite_mode => Error.NotImpl,
                Cmd.possible_completions => Error.NotImpl,
                Cmd.prefix_meta => Error.NotImpl,
                Cmd.previous_history => self.previousHistory(),
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
                Cmd.unix_word_rubout => self.unixWordRobout(),
                Cmd.upcase_word => Error.NotImpl,
                Cmd.vi_editing_mode => Error.NotImpl,
                Cmd.yank => self.yank(),
                Cmd.yank_last_arg => Error.NotImpl,
                Cmd.yank_nth_arg => Error.NotImpl,
                Cmd.yank_pop => self.yankPop(),
                Cmd.ctrl_c => {
                    //self.resetLbuf();
                    break :blk Input{ .read = Read{ .no_line = NoLine.CTRL_C } };
                },
                Cmd.no_op => {
                    break :blk edit_more;
                },
            };
        };
    }

    fn readchar(self: *Zigline) !u8 {
        var cbuf: [1]u8 = undefined;
        const read = try self.in.reader().read(&cbuf);
        if (read < 1) {
            return Error.Read;
        }
        return cbuf[0];
    }

    fn refreshLine(self: *Zigline, writer: anytype) !void {
        //TODO: maskmode  while (len--) abAppend(&ab,"*",1);
        if (self.pos > 0) {
            try std.fmt.format(writer, "\r{s}\x1b[0K\r\x1b[{d}C", .{ self.lbuf.items, self.pos });
        } else {
            try std.fmt.format(writer, "\r{s}\x1b[0K\r", .{self.lbuf.items});
        }
    }

    fn readInput(self: *Zigline) !Input {
        const c: u8 = try self.readchar();
        const cmd = try self.keyActionToCmdEmacs(c);
        const input = try self.readCmd(cmd, c);
        self.last_cmd = cmd;
        return input;
    }

    fn enableRawMode(self: *Zigline) !void {
        //obtain fd from out file
        if (!self.rawmode) {
            try _enableRawMode(posix.STDIN_FILENO);
            self.rawmode = true;
        }
    }

    fn disableRawMode(self: *Zigline) void {
        if (self.rawmode) {
            //TODO: obtain fd from out file
            const res = posix.tcsetattr(posix.STDIN_FILENO, posix.TCSA.FLUSH, orig_termios);
            if (res) {
                self.rawmode = false;
            } else |err| {
                _ = &err;
                std.debug.print("Error returned by tcssetattr", .{});
            }
        }
    }

    fn cloneToKillRing(self: *Zigline, buf: []const u8) !void {
        const text = try self.alloc.dupe(u8, buf);
        try self.kill_ring.append(text);
    }

    fn getBackwardLargeWordIndex(buf: []const u8, pos: usize) usize {
        var p = if (pos < buf.len) pos else if (buf.len > 0) buf.len - 1 else 0;
        while (p > 0 and buf[p] == ' ') {
            p -= 1;
        }
        while (p > 0 and buf[p] != ' ') {
            p -= 1;
        }
        return p;
    }

    fn getBackwardWordIndex(buf: []const u8, pos: usize) usize {
        var p = if (pos < buf.len) pos else if (buf.len > 0) buf.len - 1 else 0;
        while (p > 0 and !std.ascii.isAlphanumeric(buf[p])) {
            p -= 1;
        }
        while (p > 0 and std.ascii.isAlphanumeric(buf[p])) {
            p -= 1;
        }
        return p;
    }

    fn getForwardWordIndex(buf: []const u8, pos: usize) usize {
        var p = pos;
        while (p < buf.len and !std.ascii.isAlphanumeric(buf[p])) {
            p += 1;
        }
        while (p < buf.len and std.ascii.isAlphanumeric(buf[p])) {
            p += 1;
        }
        return p;
    }

    fn moveMemBackwards(buf: []u8, from: usize, to: usize) !void {
        if (from <= to or buf.len < from) {
            return Error.IndexError;
        }
        for (from..buf.len) |i| {
            buf[to + i - from] = buf[i];
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
    CTRL_G = 7,
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
    var raw: posix.termios = undefined;

    if (!posix.isatty(posix.STDIN_FILENO)) { //TODO: raise
        return;
    }

    orig_termios = try posix.tcgetattr(fd);

    raw = orig_termios; // modify the original mode
    // input modes: no break, no CR to NL, no parity check, no strip char,
    // no start/stop output control.
    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    // output modes - disable post processing
    raw.oflag.OPOST = false;
    // control modes - set 8 bit chars
    raw.cflag.CSIZE = std.posix.CSIZE.CS8;
    // local modes - choing off, canonical off, no extended functions, no
    // signal chars (^Z,^C)
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.lflag.ISIG = false;
    // control chars - set return condition: min number of bytes and
    // timer. We want read to return every single byte, without timeout.
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0; // 1 byte, no timer

    // put terminal in raw mode after flushing
    try posix.tcsetattr(fd, posix.TCSA.FLUSH, raw);
}
