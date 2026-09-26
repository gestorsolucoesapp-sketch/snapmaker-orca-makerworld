#include "../../src/slic3r/GUI/MakerWorldLink.hpp"
#include <iostream>
#include <stdexcept>

using namespace Slic3r::GUI::MakerWorldLink;

static unsigned checks = 0;
static void     check(bool value, const char* label)
{
    ++checks;
    if (!value)
        throw std::runtime_error(label);
}

int main()
{
    check(is_page("https://makerworld.com/pt"), "MakerWorld home");
    check(is_page("https://www.makerworld.com/en/models/123"), "www MakerWorld");
    check(is_page("HTTPS://MAKERWORLD.COM/pt"), "case-insensitive host");
    for (const auto& url : {"http://makerworld.com/pt", "https://makerworld.com.attacker.test/", "https://fakemakerworld.com/",
                            "https://makerworld.com@attacker.test/", "https://attacker.test@makerworld.com/", "file:///C:/test.3mf",
                            "https://makerworld.com:99/", "https://makerworld.com\\@attacker.test/", "https://makerworld.com./",
                            "https://makerworld.com%2fattacker.test/", "https://makerworld.com\r\n/", "https://.makerworld.com/"})
        check(!is_page(url), url);

    check(is_download("https://makerworld.bblmw.com/file.3mf?signature=abc"), "signed CDN download");
    check(!is_download("https://bblmw.com.attacker.test/a.3mf"), "CDN host suffix");
    check(!is_download("https://127.0.0.1/file.3mf"), "loopback download");
    check(!is_download("https://192.168.1.2/file.3mf"), "LAN download");

    for (const auto& url : {"bambustudio://open?file=https%3A%2F%2Fmakerworld.bblmw.com%2Fa.3mf&name=model.3mf",
                            "bambustudio://open/?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf&name=two%20colors.3mf",
                            "bambustudioopen://https%3A%2F%2Fmakerworld.bblmw.com%2Fa.3mf%3Fsig%3Dabc%26token%3D123&name=model.3mf",
                            "bambustudio://open?file=https://makerworld.com/a.3mf", "BAM BUSTUDIO://bad"}) {
        if (std::string(url) == "BAM BUSTUDIO://bad")
            check(!valid_open_link(url), "invalid scheme");
        else
            check(valid_open_link(url), url);
    }
    for (const auto& url :
         {"bambustudio://open?file=file%3A%2F%2FC%3A%2Fsecret.3mf", "bambustudio://open?file=https%3A%2F%2Fattacker.test%2Fa.3mf",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com.attacker.test%2Fa.3mf",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%40attacker.test%2Fa.3mf",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf&name=..%2Foverwrite.3mf",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf&name=C%3A%5Coverwrite.3mf",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf&name=job.gcode",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf&name=model.3mf%00",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf&name=model.3mf&other=bad",
          "bambustudio://open?file=https%253A%252F%252Fmakerworld.com%252Fa.3mf",
          "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf%", "bambustudio://open?file=https%3A%2F%2Fmakerworld.com%2Fa.3mf%0A",
          "bambustudio://print?file=https://makerworld.com/a.3mf", "bambustudioopen://", "javascript:alert(1)"})
        check(!valid_open_link(url), url);
    check(!valid_open_link("bambustudioopen://https://makerworld.com/" + std::string(65536, 'a')), "oversized URI");
    std::string decoded;
    check(unescape("a+b%20c", decoded) && decoded == "a+b c", "literal plus survives signed URL decoding");
    check(!unescape("%GG", decoded), "invalid hex rejected");
    std::cout << checks << " MakerWorld link checks passed\n";
}
