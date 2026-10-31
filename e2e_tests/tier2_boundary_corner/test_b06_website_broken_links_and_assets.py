import unittest
import re
from pathlib import Path
from e2e_tests.common.test_base import RelayE2ETestBase

class TestB06WebsiteBrokenLinksAndAssets(RelayE2ETestBase):
    """
    Boundary B06: Website 404 Links & Asset Integrity
    Verifies that all internal links, anchors (#id), CSS stylesheets,
    JavaScript engines, and SVG icons in /website exist without 404 errors.
    """

    def setUp(self):
        self.index_file = self.website_dir / "index.html"
        self.privacy_file = self.website_dir / "privacy.html"
        self.assertTrue(self.index_file.exists())
        self.assertTrue(self.privacy_file.exists())
        self.index_html = self.index_file.read_text(encoding="utf-8")
        self.privacy_html = self.privacy_file.read_text(encoding="utf-8")

    def test_b06_01_all_local_html_hrefs_resolve(self):
        """Verifies all relative .html link destinations exist on disk."""
        for html_file, content in [(self.index_file, self.index_html), (self.privacy_file, self.privacy_html)]:
            hrefs = re.findall(r'href=["\']([^"\'#]+(?:\.html)?(?:#[^"\']*)?)["\']', content)
            for href in hrefs:
                if href.startswith("http") or href.startswith("mailto:"):
                    continue
                clean_target = href.split("#")[0]
                if clean_target:
                    target_path = self.website_dir / clean_target
                    self.assertTrue(target_path.exists(), f"Broken relative href '{href}' in {html_file.name}")

    def test_b06_02_all_internal_anchor_ids_exist(self):
        """Verifies all #anchor links match an element id in the same document."""
        for html_file, content in [(self.index_file, self.index_html), (self.privacy_file, self.privacy_html)]:
            anchors = re.findall(r'href=["\']#([^"\']+)["\']', content)
            for anchor in anchors:
                pattern = f'id="{anchor}"'
                self.assertIn(pattern, content, f"Missing target element id='{anchor}' in {html_file.name}")

    def test_b06_03_all_stylesheet_links_exist(self):
        """Verifies all CSS link tags point to existing stylesheets."""
        for html_file, content in [(self.index_file, self.index_html), (self.privacy_file, self.privacy_html)]:
            css_links = re.findall(r'<link[^>]+href=["\']([^"\']+\.css)["\']', content)
            for css in css_links:
                css_path = self.website_dir / css
                self.assertTrue(css_path.exists(), f"Referenced CSS file {css} in {html_file.name} does not exist")

    def test_b06_04_all_script_srcs_exist(self):
        """Verifies all script src tags point to existing JS files."""
        for html_file, content in [(self.index_file, self.index_html), (self.privacy_file, self.privacy_html)]:
            js_links = re.findall(r'<script[^>]+src=["\']([^"\']+\.js)["\']', content)
            for js in js_links:
                js_path = self.website_dir / js
                self.assertTrue(js_path.exists(), f"Referenced JS file {js} in {html_file.name} does not exist")

    def test_b06_05_all_image_svg_srcs_exist(self):
        """Verifies all img src and svg icon links point to existing assets."""
        for html_file, content in [(self.index_file, self.index_html), (self.privacy_file, self.privacy_html)]:
            img_srcs = re.findall(r'src=["\'](assets/[^"\']+)["\']', content)
            icon_hrefs = re.findall(r'href=["\'](assets/[^"\']+)["\']', content)
            for asset in img_srcs + icon_hrefs:
                asset_path = self.website_dir / asset
                self.assertTrue(asset_path.exists(), f"Referenced asset {asset} in {html_file.name} does not exist")
