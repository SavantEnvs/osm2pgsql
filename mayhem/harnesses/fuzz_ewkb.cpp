// Fuzz the EWKB geometry decoder ewkb_to_geom() (wkb.cpp), which osm2pgsql
// applies to geometries read back from the database (expire-from-result,
// locator, generalization), and what it feeds: geometry functions, the
// encoder geom_to_ewkb() and tile expiry of EPSG:3857 geometries.
#include "expire-config.hpp"
#include "expire-tiles.hpp"
#include "geom-functions.hpp"
#include "geom.hpp"
#include "logging.hpp"
#include "reprojection.hpp"
#include "wkb.hpp"

#include <cstddef>
#include <cstdint>
#include <exception>
#include <string_view>

namespace {

// PostGIS never writes the SRID flag with SRID 0, never writes an SRID on a
// collection member, and every osm2pgsql caller of geom_to_ewkb() passes a
// projected geometry, which always has a non-zero SRID. The parser accepts
// both, so the harness only hands geometries a real caller could hold to the
// functions that assert on them (wkb.cpp make_ewkb_visitor_t, spherical_*).
bool members_latlong(geom::geometry_t const &geom)
{
    if (geom.srid() != PROJ_LATLONG) {
        return false;
    }
    if (!geom.is_collection()) {
        return true;
    }
    for (auto const &member : geom.get<geom::collection_t>()) {
        if (!members_latlong(member)) {
            return false;
        }
    }
    return true;
}

// osm2pgsql only builds flat collections (geom-from-osm.cpp
// create_collection); centroid() asserts on nested ones.
bool has_nested_collection(geom::geometry_t const &geom)
{
    if (!geom.is_collection()) {
        return false;
    }
    for (auto const &member : geom.get<geom::collection_t>()) {
        if (member.is_collection()) {
            return true;
        }
    }
    return false;
}

} // anonymous namespace

extern "C" int LLVMFuzzerTestOneInput(uint8_t const *data, size_t size)
{
    get_logger().set_level(log_level::error);
    try {
        auto const geom = ewkb_to_geom(
            std::string_view{reinterpret_cast<char const *>(data), size});

        if (geom.srid() != 0) {
            auto const wkb = geom_to_ewkb(geom);
            auto const again = ewkb_to_geom(wkb);
            (void)again;
        }

        (void)geom::geometry_type(geom);
        (void)geom::num_geometries(geom);
        (void)geom::area(geom);
        (void)geom::length(geom);
        if (!has_nested_collection(geom)) {
            (void)geom::centroid(geom);
        }
        (void)geom::reverse(geom);
        (void)geom::line_merge(geom);
        (void)geom::simplify(geom, 1.0);
        (void)geom::geometry_n(geom, 1);
        if (members_latlong(geom)) {
            (void)geom::spherical_area(geom);
            (void)geom::spherical_length(geom);
        }

        // expire_tiles_t::from_result() passes ewkb_to_geom() output from
        // the database straight to from_geometry(): no filtering here.
        auto const proj = reprojection_t::create_projection(PROJ_SPHERE_MERC);
        expire_tiles_t expire{10, proj};
        expire_config_t cfg;
        expire.from_geometry_if_3857(geom, cfg);
    } catch (std::exception const &) {
    }
    return 0;
}
