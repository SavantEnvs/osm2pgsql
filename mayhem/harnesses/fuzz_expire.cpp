// Fuzz the osm2pgsql-expire pipeline on an OSM data file: libosmium reader
// (format FUZZ_FORMAT: pbf / xml / opl / o5m) -> osmdata_t -> middle_ram_t
// (node-locations, ordered-index) -> geometry assembly (points, lines,
// polygons, multipolygons) -> tile expiry. This is the tool's own main()
// logic with the input coming from a memory buffer instead of a named file.
//
// The tool's source is included so its output_expire_t (anonymous
// namespace) is reused verbatim; its main() is renamed out of the way.
#define main osm2pgsql_expire_main
#include "osm2pgsql-expire.cpp"
#undef main

#include <cstddef>
#include <cstdint>

#ifndef FUZZ_FORMAT
#error "define FUZZ_FORMAT"
#endif

extern "C" int LLVMFuzzerTestOneInput(uint8_t const *data, size_t size)
{
    // Process-global logger: reset each input (nothing else is kept).
    get_logger().set_level(log_level::error);
    get_logger().disable_progress();

    try {
        config_t cfg;
        cfg.projection = reprojection_t::create_projection(PROJ_SPHERE_MERC);
        cfg.zoom = 10;
        cfg.expire_config.mode = expire_mode::full_area;

        auto thread_pool = std::make_shared<thread_pool_t>(1U);
        options_t options;
        options.projection = cfg.projection;
        auto middle = create_middle(thread_pool, options);
        middle->start();

        auto output = std::make_shared<output_expire_t>(
            middle->get_query_instance(), thread_pool, options, cfg);

        osmdata_t osmdata{middle, output, options};

        std::vector<osmium::io::File> files;
        files.emplace_back(reinterpret_cast<char const *>(data), size,
                           FUZZ_FORMAT);
        process_files(files, &osmdata, false, false);
    } catch (std::exception const &) {
        // invalid input is reported by the tool as an error, not a crash
    }
    return 0;
}
