const std = @import("std");

// Generic global registry map per name+type.
// Matches spec bullet 10 verbatim.
pub fn Map(comptime name: anytype, comptime data_: type) type {
    _ = name;
    return struct {
        var common_data: ?Data = null;

        pub fn get(default: Data) Data {
            return common_data orelse default;
        }

        pub fn set(data: Data) void {
            common_data = data;
        }

        pub const Data = data_;
    };
}
