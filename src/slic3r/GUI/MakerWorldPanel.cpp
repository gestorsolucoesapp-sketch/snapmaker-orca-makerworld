#include "MakerWorldPanel.hpp"
#include "MakerWorldLink.hpp"
#include "GUI_App.hpp"
#include "I18N.hpp"
#include "Plater.hpp"
#include "libslic3r/AppConfig.hpp"

#include <wx/button.h>
#include <wx/dirdlg.h>
#include <wx/filename.h>
#include <wx/msgdlg.h>
#include <wx/sizer.h>
#include <wx/stattext.h>
#include <wx/utils.h>

namespace Slic3r { namespace GUI {

static const wxString makerworld_home = "https://makerworld.com/pt";

MakerWorldPanel::MakerWorldPanel(wxWindow* parent) : wxPanel(parent, wxID_ANY)
{
    auto* layout   = new wxBoxSizer(wxVERTICAL);
    auto* toolbar  = new wxBoxSizer(wxHORIZONTAL);
    m_back         = new wxButton(this, wxID_ANY, _L("Back"));
    m_forward      = new wxButton(this, wxID_ANY, _L("Forward"));
    auto* home     = new wxButton(this, wxID_ANY, "MakerWorld");
    auto* reload   = new wxButton(this, wxID_ANY, _L("Reload"));
    auto* external = new wxButton(this, wxID_ANY, _L("Open in browser"));
    for (auto* button : {m_back, m_forward, home, reload, external})
        toolbar->Add(button, 0, wxALL, FromDIP(4));
    layout->Add(toolbar, 0, wxEXPAND);
    m_status = new wxStaticText(
        this, wxID_ANY,
        _L("Open a model with 'Open in Bambu Studio'. Then select your U1 printer and review the filament mapping before slicing."));
    layout->Add(m_status, 0, wxEXPAND | wxALL, FromDIP(8));
    SetSizer(layout);
    m_back->Disable();
    m_forward->Disable();

    // Do not contact MakerWorld until the user opens this tab.
    Bind(wxEVT_SHOW, [this](wxShowEvent& event) {
        if (event.IsShown() && !m_browser)
            create_browser();
        event.Skip();
    });
    m_back->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) {
        if (m_browser && m_browser->CanGoBack())
            m_browser->GoBack();
    });
    m_forward->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) {
        if (m_browser && m_browser->CanGoForward())
            m_browser->GoForward();
    });
    home->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) {
        if (m_browser)
            m_browser->LoadURL(makerworld_home);
        else
            create_browser();
    });
    reload->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) {
        if (m_browser)
            m_browser->Reload();
        else
            create_browser();
    });
    external->Bind(wxEVT_BUTTON, [this](wxCommandEvent&) {
        const auto url = m_browser ? m_browser->GetCurrentURL() : makerworld_home;
        wxLaunchDefaultBrowser(MakerWorldLink::is_page(url.ToStdString()) ? url : makerworld_home);
    });
}

void MakerWorldPanel::create_browser()
{
    if (m_browser) {
        return;
    }
    // The application's WebView factory registers a privileged native message bridge.
    // Public web content must use a plain web view with NO native script handlers.
#ifdef __WXMSW__
    m_browser = wxWebView::New(this, wxID_ANY, "about:blank", wxDefaultPosition, wxDefaultSize, wxWebViewBackendEdge);
#else
    m_browser = wxWebView::New(this, wxID_ANY, "about:blank");
#endif
    if (!m_browser) {
        m_status->SetLabel(_L("The embedded browser could not start. Use 'Open in browser' or try again."));
        return;
    }
    m_browser->Bind(wxEVT_WEBVIEW_NAVIGATING, &MakerWorldPanel::navigate, this);
    m_browser->Bind(wxEVT_WEBVIEW_NEWWINDOW, &MakerWorldPanel::new_window, this);
    m_browser->Bind(wxEVT_WEBVIEW_NAVIGATED, [this](wxWebViewEvent&) { update_navigation(); });
    m_browser->Bind(wxEVT_WEBVIEW_LOADED, [this](wxWebViewEvent&) { update_navigation(); });
    m_browser->Bind(wxEVT_WEBVIEW_ERROR, [this](wxWebViewEvent& event) {
        if (MakerWorldLink::is_open_scheme(event.GetURL().ToStdString()))
            return;
        m_status->SetLabel(_L("The page could not load. Try Reload or Open in browser."));
        Layout();
    });
    GetSizer()->Add(m_browser, 1, wxEXPAND);
    Layout();
    m_browser->LoadURL(makerworld_home);
}

void MakerWorldPanel::update_navigation()
{
    m_back->Enable(m_browser && m_browser->CanGoBack());
    m_forward->Enable(m_browser && m_browser->CanGoForward());
}

void MakerWorldPanel::navigate(wxWebViewEvent& event)
{
    const auto url = event.GetURL().ToStdString();
    if (MakerWorldLink::is_open_scheme(url)) {
        event.Veto();
        open_model(event.GetURL());
        return;
    }
    // HTTPS navigation permits normal sign-in redirects. Local files, executable
    // protocols and HTTP downgrades are never launched.
    if (url != "about:blank" && MakerWorldLink::https_host(url).empty()) {
        event.Veto();
        return;
    }
    event.Skip();
}

void MakerWorldPanel::new_window(wxWebViewEvent& event)
{
    const auto url = event.GetURL().ToStdString();
    if (MakerWorldLink::is_open_scheme(url))
        open_model(event.GetURL());
    else if (!MakerWorldLink::https_host(url).empty())
        m_browser->LoadURL(event.GetURL());
    // No OS protocol handler: Bambu Studio's association remains unchanged.
}

void MakerWorldPanel::open_model(const wxString& url)
{
    if (m_import_pending || !m_browser)
        return;
    if (!MakerWorldLink::is_page(m_browser->GetCurrentURL().ToStdString()) || !MakerWorldLink::valid_open_link(url.ToStdString())) {
        m_status->SetLabel(_L("This model link is not supported. Download its 3MF file and open it from the File menu."));
        Layout();
        return;
    }
    m_import_pending = true;
    // Leave the web-view callback before showing save/folder dialogs or importing.
    CallAfter([this, url] {
        auto* plater = wxGetApp().plater();
        if (!plater || plater->save_project_if_dirty(_L("Opening a MakerWorld model")) == wxID_CANCEL) {
            m_import_pending = false;
            return;
        }
        const auto path = wxString::FromUTF8(wxGetApp().app_config->get("download_path"));
        if (path.empty() || !wxFileName::DirExists(path)) {
            wxDirDialog folder(this, _L("Choose Download Directory"), wxEmptyString, wxDD_DEFAULT_STYLE);
            if (folder.ShowModal() != wxID_OK) {
                m_import_pending = false;
                return;
            }
            wxGetApp().app_config->set("download_path", folder.GetPath().ToStdString());
            wxGetApp().app_config->save();
        }
        wxGetApp().start_download(url.ToStdString());
        m_import_pending = false;
    });
}

}} // namespace Slic3r::GUI
