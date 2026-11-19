// Fuzz the osm2pgsql command line parser parse_command_line()
// (command-line-parser.cpp, command-line-app.cpp, CLI11 and the option
// checks: bbox, projections, expire settings, numbers, connection params).
// The input is split on NUL bytes into argv after argv[0] = "osm2pgsql".
#include "command-line-parser.hpp"
#include "logging.hpp"
#include "options.hpp"

#include <cstddef>
#include <cstdint>
#include <exception>
#include <string>
#include <vector>

extern "C" int LLVMFuzzerTestOneInput(uint8_t const *data, size_t size)
{
    // The parser changes the process-global logger (--log-level, --log-sql
    // ...); reset it per input.
    get_logger().set_level(log_level::error);
    get_logger().disable_progress();

    std::vector<std::string> args{"osm2pgsql"};
    std::string cur;
    for (size_t i = 0; i < size; ++i) {
        if (data[i] == '\0') {
            args.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(static_cast<char>(data[i]));
        }
    }
    args.push_back(cur);

    std::vector<char *> argv;
    argv.reserve(args.size() + 1);
    for (auto &a : args) {
        argv.push_back(a.data());
    }
    argv.push_back(nullptr);

    try {
        auto const options =
            parse_command_line(static_cast<int>(args.size()), argv.data());
        (void)options;
    } catch (std::exception const &) {
    }
    get_logger().set_level(log_level::error);
    return 0;
}
