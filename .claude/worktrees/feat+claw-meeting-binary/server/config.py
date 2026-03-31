"""Shared constants for the context bridge server."""

# Canonical portfolio project list.
PORTFOLIO_PROJECTS = {
    'prescrivia': ['prescrivia'],
    'leverwork': ['leverwork'],
    'sonopeace': ['sonopeace'],
    'jsvhq': ['jsvhq', 'jsvcapital'],
    'openclaw': ['openclaw-computer-vision', 'openclaw-macos-helper', 'clawd'],
}

# Extended project list including non-portfolio projects.
ALL_PROJECTS = {
    **PORTFOLIO_PROJECTS,
    'aeoa': ['aeoa', 'aeoa-studio'],
    'nilsy': ['nilsy'],
    'legal': ['mcol', 'sehaj', 'azika', 'sorna', 'rohu'],
}

# Apps that generate noise and should be excluded from time tracking.
NOISE_APPS = {'Finder', 'SystemUIServer', 'loginwindow', 'Dock', 'Spotlight'}
