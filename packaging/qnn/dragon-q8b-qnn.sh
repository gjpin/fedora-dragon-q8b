# Environment configuration for Qualcomm QNN SDK on Radxa Dragon Q8B
if [ -d "/opt/qualcomm/qnn/current" ]; then
    export QNN_SDK_ROOT="/opt/qualcomm/qnn/current"
    if [ -d "${QNN_SDK_ROOT}/bin/aarch64-linux-gnu" ]; then
        export PATH="${QNN_SDK_ROOT}/bin/aarch64-linux-gnu:${PATH}"
    fi
    if [ -d "${QNN_SDK_ROOT}/lib/hexagon-v69" ]; then
        export ADSP_LIBRARY_PATH="${QNN_SDK_ROOT}/lib/hexagon-v69;${ADSP_LIBRARY_PATH:-/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp/cdsp;/usr/lib/rfsa/adsp;/dsp}"
    fi
fi
