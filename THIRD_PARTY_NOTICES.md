# Third-party notices

CRDSClient.jl is under the MIT license (`LICENSE`). Parts of it are translations into Julia of code
from the Python packages below, or are generated from their data; their copyright notices and licenses
follow. These packages are developed by the Space Telescope Science Institute (STScI); CRDSClient.jl is
an independent project, not endorsed by STScI or AURA.

## crds (CRDS client)

<https://github.com/spacetelescope/crds>

Ported, as translated logic rather than copied code:

- `crds/core/selectors.py`: the lookup half of `MatchSelector`, `UseAfterSelector` and
  `VersionAfterSelector`, the matcher classes and `matcher()`, `glob_list`, `esoteric_key`, the default
  substitutions and the header value check (`_validate_value`) → `src/selectors.jl`.
- `crds/core/utils.py` (`condition_value`, its regular expressions), `crds/core/timestamp.py`
  (`reformat_date`), `crds/core/config.py` (`simplify_version`, `VERSION_RE`, the cache path precedence
  of `_std_cache_path`, the reference cache subdirectory mode, the default server URLs) →
  `src/selectors.jl`, `src/config.jl`, `src/api.jl`.
- `crds/core/rmap.py`, `crds/core/heavy_client.py`, `crds/core/constants.py`: the best-reference flow
  (`get_best_ref`, `reffile_required`, `INSTRUMENT_KEYWORDS`, not-applicable and omit values) →
  `src/mappings.jl`.
- `crds/roman/locate.py` (`dataset_to_ref_header`) and `crds/jwst/locate.py` (`fits_to_parkeys`) →
  `src/mappings.jl`, `src/jwst.jl`.
- `crds/hst/siname.py` (`WhichCDBSInstrument`, the instrument letters) and `crds/hst/locate.py`
  (`instrument_from_refname`): the instrument folder of an HST reference name → `src/api.jl`.
- The doctests of `GlobMatcher`, `InequalityMatcher` and `VersionAfterSelector` → `test/runtests.jl`.

```
Copyright (C) 2010 Association of Universities for Research in Astronomy(AURA)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    3. The name of AURA and its representatives may not be used to
      endorse or promote products derived from this software without
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY AURA ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL AURA BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.
```

## stdatamodels (JWST data models)

<https://github.com/spacetelescope/stdatamodels>

- `src/jwst_keywords.jl` (the FITS keyword → data-model path table) is generated from the
  `JwstDataModel` schema by `gen/jwst_fits_keywords.py`, which walks the schema as
  `stdatamodels.schema.find_fits_keyword` does.

```
Copyright (C) 2020 Association of Universities for Research in Astronomy (AURA)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    1. Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.

    2. Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.

    3. The name of AURA and its representatives may not be used to
      endorse or promote products derived from this software without
      specific prior written permission.

THIS SOFTWARE IS PROVIDED BY AURA ``AS IS'' AND ANY EXPRESS OR IMPLIED
WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL AURA BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS
OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
DAMAGE.
```
