# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

import Config

# Recommended by Ash: counts unicode codepoints, which is how SQL data layers
# count string length, so validation is consistent everywhere.
config :ash, default_string_length_count: :codepoints
