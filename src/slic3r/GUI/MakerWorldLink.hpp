#ifndef slic3r_MakerWorldLink_hpp_
#define slic3r_MakerWorldLink_hpp_

#include <algorithm>
#include <cctype>
#include <string>

namespace Slic3r { namespace GUI { namespace MakerWorldLink {

inline std::string lower(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return std::tolower(c); });
    return value;
}

inline bool has_domain(const std::string& host, const std::string& domain)
{
    return host == domain ||
           (host.size() > domain.size() && host.compare(host.size() - domain.size() - 1, domain.size() + 1, "." + domain) == 0);
}

// Only canonical HTTPS authorities: no credentials, custom ports, escapes or backslashes.
inline std::string https_host(const std::string& url)
{
    if (lower(url.substr(0, 8)) != "https://" ||
        std::any_of(url.begin(), url.end(), [](unsigned char c) { return c <= 32 || c == 127 || c == '\\'; }))
        return {};
    const auto end  = url.find_first_of("/?#", 8);
    auto       host = lower(url.substr(8, end == std::string::npos ? end : end - 8));
    if (host.empty() || host.front() == '.' || host.back() == '.' || host.find("..") != std::string::npos ||
        std::any_of(host.begin(), host.end(),
                    [](unsigned char c) { return !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.'); }))
        return {};
    return host;
}

inline bool is_page(const std::string& url) { return has_domain(https_host(url), "makerworld.com"); }

inline bool is_download(const std::string& url)
{
    const auto host = https_host(url);
    return has_domain(host, "makerworld.com") || has_domain(host, "bblmw.com") || has_domain(host, "bambulab.com") ||
           has_domain(host, "bblcdn.com");
}

inline int hex_digit(char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

inline bool unescape(const std::string& input, std::string& output)
{
    output.clear();
    for (size_t i = 0; i < input.size(); ++i) {
        unsigned char c = input[i];
        if (c == '%') {
            if (i + 2 >= input.size() || hex_digit(input[i + 1]) < 0 || hex_digit(input[i + 2]) < 0)
                return false;
            c = static_cast<unsigned char>(hex_digit(input[i + 1]) * 16 + hex_digit(input[i + 2]));
            i += 2;
        }
        if (c < 32 || c == 127)
            return false;
        output += static_cast<char>(c);
    }
    return true;
}

inline bool is_open_scheme(const std::string& url)
{
    const auto scheme = lower(url.substr(0, url.find(':')));
    return scheme == "bambustudio" || scheme == "bambustudioopen";
}

// Return the original URI, never a decoded/re-encoded signed download URL.
// Decoder behavior matches Downloader's single unescape step.
inline bool valid_open_link(const std::string& url)
{
    if (url.size() > 65536)
        return false;
    const auto normalized = lower(url);
    size_t     start      = std::string::npos;
    for (const std::string prefix : {"bambustudio://open?file=", "bambustudio://open/?file=", "bambustudioopen://"}) {
        if (normalized.compare(0, prefix.size(), prefix) == 0) {
            start = prefix.size();
            break;
        }
    }
    if (start == std::string::npos)
        return false;
    const auto  name_pos = url.find("&name=", start);
    std::string download;
    if (!unescape(url.substr(start, name_pos == std::string::npos ? name_pos : name_pos - start), download) || !is_download(download))
        return false;
    if (name_pos != std::string::npos) {
        std::string name;
        if (!unescape(url.substr(name_pos + 6), name) || name.empty() || name.size() > 240 ||
            name.find_first_of("/\\:*?\"<>|&") != std::string::npos || name.front() == '.' || name.size() < 5 ||
            lower(name.substr(name.size() - 4)) != ".3mf")
            return false;
    }
    return true;
}

}}} // namespace Slic3r::GUI::MakerWorldLink
#endif
