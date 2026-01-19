# Sphinx configuration for Axion-Common documentation

import os
import sys

# Project information
project = 'Axion-Common'
copyright = '2026, Bugra Tufan'
author = 'Bugra Tufan'

# Get version from .version file
version_file = os.path.join(os.path.dirname(__file__), '../../.version')
if os.path.exists(version_file):
    with open(version_file) as f:
        release = f.read().strip()
else:
    release = '0.0.0'

version = '.'.join(release.split('.')[:2])

# Extensions
extensions = [
    'sphinx.ext.viewcode',
    'sphinx.ext.intersphinx',
    'myst_parser',
]

# MyST parser for Markdown support
myst_enable_extensions = [
    'colon_fence',
    'deflist',
]

# Theme
html_theme = 'sphinx_rtd_theme'

# Source file suffixes
source_suffix = {
    '.rst': 'restructuredtext',
    '.md': 'markdown',
}

# The master document
master_doc = 'index'

# Templates and static files
templates_path = ['_templates']
exclude_patterns = []
