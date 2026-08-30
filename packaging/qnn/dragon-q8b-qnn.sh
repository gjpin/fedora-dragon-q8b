# Environment for a user-installed Qualcomm QAIRT/QNN SDK on Dragon Q8B.
if [ -d /opt/qualcomm/qairt/current ]; then
    export QNN_SDK_ROOT=/opt/qualcomm/qairt/current
    export QAIRT_SDK_ROOT=/opt/qualcomm/qairt/current
    export QNN_TARGET=aarch64-oe-linux-gcc11.2
    export QNN_DSP_ARCH=68
    export PATH="${QNN_SDK_ROOT}/bin/${QNN_TARGET}:${PATH}"
    export ADSP_LIBRARY_PATH="${QNN_SDK_ROOT}/lib/hexagon-v${QNN_DSP_ARCH}/unsigned;${ADSP_LIBRARY_PATH:-/usr/share/qcom/sc8280xp/radxa/dragon-q8b/dsp/cdsp;/usr/lib/rfsa/adsp;/dsp}"
fi
