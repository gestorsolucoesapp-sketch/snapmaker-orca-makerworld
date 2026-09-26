#ifndef slic3r_MakerWorldPanel_hpp_
#define slic3r_MakerWorldPanel_hpp_

#include <wx/panel.h>
#include <wx/webview.h>

class wxButton;
class wxStaticText;

namespace Slic3r { namespace GUI {

class MakerWorldPanel : public wxPanel
{
public:
    explicit MakerWorldPanel(wxWindow* parent);

private:
    void create_browser();
    void navigate(wxWebViewEvent& event);
    void new_window(wxWebViewEvent& event);
    void open_model(const wxString& url);
    void update_navigation();

    wxWebView*    m_browser        = nullptr;
    wxButton*     m_back           = nullptr;
    wxButton*     m_forward        = nullptr;
    wxStaticText* m_status         = nullptr;
    bool          m_import_pending = false;
};

}} // namespace Slic3r::GUI
#endif
