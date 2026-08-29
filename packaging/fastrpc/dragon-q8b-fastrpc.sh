# FastRPC DSP search paths for Radxa Dragon Q8B
if [ -z "${ADSP_LIBRARY_PATH:-}" ]; then
    export ADSP_LIBRARY_PATH="/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp/cdsp;/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp/adsp;/usr/lib/rfsa/adsp;/dsp"
fi
