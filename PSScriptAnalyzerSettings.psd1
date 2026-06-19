# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 CEC-Autosetep contributors
#
# PSScriptAnalyzer settings. All Error-level rules stay on (CI fails on any
# error). The excluded rules below are intentional design choices for a
# first-boot console tool; each is justified inline.

@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        # Write-Log renders coloured, operator-facing status on first boot;
        # console output is the point, not a side effect.
        'PSAvoidUsingWriteHost',

        # Several helpers intentionally return collections
        # (Get-Peripherals, Get-AsusSeriesCandidates, Find-MatchingApps, ...).
        'PSUseSingularNouns',

        # Best-effort operations (TLS enable, logging, temp cleanup) deliberately
        # swallow failures so they never break an unattended run.
        'PSAvoidUsingEmptyCatchBlock',

        # Write-Log is a conventional custom function name here, not the cmdlet
        # from any shipped module.
        'PSAvoidOverwritingBuiltInCmdlets',

        # Provider contract parity: some providers accept $Identity/$Osid to match
        # the common signature even when they do not use them (e.g. ASRock).
        'PSReviewUnusedParameter',

        # Initialize-Log and similar must always run (we want a transcript even
        # under -WhatIf). True state-changers already use SupportsShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions',

        # Comment-based help is provided on public surface; not required on every
        # internal helper.
        'PSProvideCommentHelp',

        # OutputType attributes add noise without value for this codebase.
        'PSUseOutputTypeCorrectly'
    )
}
