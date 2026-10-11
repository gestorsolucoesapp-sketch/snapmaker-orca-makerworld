#ifndef slic3r_ModelLibraries_hpp_
#define slic3r_ModelLibraries_hpp_

#include "MakerWorldLink.hpp"

#include <array>
#include <cstddef>
#include <string>

namespace Slic3r { namespace GUI { namespace ModelLibraries {

struct Library
{
    const char* name;
    const char* home;
    const char* domain;
    bool        supports_direct_import;
};

inline constexpr std::array<Library, 5> libraries = {{
    {"MakerWorld", "https://makerworld.com/pt", "makerworld.com", true},
    {"Printables (Prusa)", "https://www.printables.com/", "printables.com", false},
    {"Thingiverse", "https://www.thingiverse.com/", "thingiverse.com", false},
    {"MyMiniFactory", "https://www.myminifactory.com/", "myminifactory.com", false},
    {"Cults3D", "https://cults3d.com/", "cults3d.com", false},
}};

inline const Library& selected(int index)
{
    return libraries[index >= 0 && static_cast<std::size_t>(index) < libraries.size() ? static_cast<std::size_t>(index) : 0];
}

inline bool is_selected_page(const std::string& url, int index)
{
    return MakerWorldLink::has_domain(MakerWorldLink::https_host(url), selected(index).domain);
}

}}} // namespace Slic3r::GUI::ModelLibraries
#endif
