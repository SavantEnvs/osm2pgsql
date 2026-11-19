// Fuzz the pgsql-output style file reader read_style_file() (taginfo.cpp,
// incl. parse_tag_flags) and the built-in C tag transform built from the
// parsed export list (tagtransform-c.cpp, wildcmp.cpp), applied to a fixed
// set of OSM objects.
#include "logging.hpp"
#include "options.hpp"
#include "osmtypes.hpp"
#include "taginfo-impl.hpp"
#include "tagtransform.hpp"

#include <osmium/io/any_input.hpp>
#include <osmium/memory/buffer.hpp>
#include <osmium/osm.hpp>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <unistd.h>

namespace {

// Read-only after initialization: the objects the transform is applied to.
osmium::memory::Buffer *g_objects = nullptr;
std::string g_path;

char const OBJECTS[] =
    "n1 v1 Tamenity=restaurant,name=Foo,addr:street=Main,building=yes "
    "x1.0 y2.0\n"
    "n2 v1 Thighway=traffic_signals,area=no x1.1 y2.1\n"
    "w10 v1 Thighway=primary,name=Main,oneway=yes,layer=1,bridge=yes "
    "Nn1,n2\n"
    "w11 v1 Tbuilding=yes,landuse=residential,area=yes,z_order=3 "
    "Nn1,n2,n1\n"
    "w12 v1 Tnatural=coastline,waterway=riverbank,tunnel=no Nn1,n2\n"
    "r20 v1 Ttype=multipolygon,landuse=forest,name:de=Wald "
    "Mw10@outer,w11@inner\n"
    "r21 v1 Ttype=route,route=bus,ref=7,network=x Mn1@stop,w10@\n"
    "r22 v1 Ttype=boundary,boundary=administrative,admin_level=8 Mw12@\n";

} // namespace

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    osmium::io::File file{OBJECTS, sizeof(OBJECTS) - 1, "opl"};
    osmium::io::Reader reader{file};
    g_objects = new osmium::memory::Buffer{reader.read()};
    reader.close();

    char const *tmp = std::getenv("TMPDIR");
    std::string tmpl = std::string{(tmp && *tmp) ? tmp : "/tmp"} +
                       "/fuzz_style_XXXXXX";
    int fd = mkstemp(tmpl.data());
    if (fd < 0) {
        std::abort();
    }
    close(fd);
    g_path = tmpl;
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(uint8_t const *data, size_t size)
{
    get_logger().set_level(log_level::error);

    FILE *f = std::fopen(g_path.c_str(), "wb");
    if (!f) {
        std::abort();
    }
    if (size && std::fwrite(data, 1, size, f) != size) {
        std::abort();
    }
    std::fclose(f);

    try {
        export_list_t exlist;
        bool const ok = read_style_file(g_path, &exlist);
        (void)ok;
        for (auto type : {osmium::item_type::node, osmium::item_type::way}) {
            (void)exlist.normal_columns(type);
        }

        options_t options;
        auto transform = tagtransform_t::make_tagtransform(&options, exlist);
        for (auto const &obj : g_objects->select<osmium::OSMObject>()) {
            bool polygon = false;
            bool roads = false;
            taglist_t out;
            transform->filter_tags(obj, &polygon, &roads, &out);
        }
    } catch (std::exception const &) {
    }
    return 0;
}
