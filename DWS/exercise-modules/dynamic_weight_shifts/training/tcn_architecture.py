"""Four-class temporal architecture for seated Dynamic Weight Shifts."""

from __future__ import annotations


def residual_block(tf, inputs, filters: int, dilation: int, dropout: float, name: str):
    residual = inputs
    hidden = tf.keras.layers.Conv1D(
        filters,
        3,
        padding="causal",
        dilation_rate=dilation,
        use_bias=False,
        name=f"{name}_conv1",
    )(inputs)
    hidden = tf.keras.layers.LayerNormalization(name=f"{name}_norm1")(hidden)
    hidden = tf.keras.layers.Activation("relu", name=f"{name}_relu1")(hidden)
    hidden = tf.keras.layers.SpatialDropout1D(dropout, name=f"{name}_drop1")(hidden)
    hidden = tf.keras.layers.Conv1D(
        filters,
        3,
        padding="causal",
        dilation_rate=dilation,
        use_bias=False,
        name=f"{name}_conv2",
    )(hidden)
    hidden = tf.keras.layers.LayerNormalization(name=f"{name}_norm2")(hidden)
    hidden = tf.keras.layers.Activation("relu", name=f"{name}_relu2")(hidden)
    if int(inputs.shape[-1]) != filters:
        residual = tf.keras.layers.Conv1D(filters, 1, padding="same", name=f"{name}_residual")(residual)
    return tf.keras.layers.Activation("relu", name=f"{name}_out")(
        tf.keras.layers.Add(name=f"{name}_add")([residual, hidden])
    )


def build_model(tf, payload: dict, filters: int, dropout: float):
    """Use the full landmark sequence for form and anatomical direction.

    This exercise owns a temporal shoulder/hip head. The legacy trunk_shift
    joint angle is never persisted or fed to the model. Direction-specific
    profiles may append hip-anchored torso geometry defined in the feature
    manifest; absolute hip translation is excluded.
    """

    input_shape = tuple(payload["inputShape"])
    inputs = tf.keras.Input(shape=input_shape, name="motion_window")
    sequence = tf.keras.layers.LayerNormalization(name="motion_input_normalization")(inputs)
    for dilation in (1, 2, 4, 8):
        sequence = residual_block(
            tf,
            sequence,
            filters=max(16, filters),
            dilation=dilation,
            dropout=max(0.0, min(0.5, dropout)),
            name=f"motion_tcn_d{dilation}",
        )

    last_context = tf.keras.layers.Cropping1D(
        cropping=(max(0, input_shape[0] - 1), 0),
        name="last_timestep",
    )(sequence)
    last_context = tf.keras.layers.Flatten(name="last_motion_context")(last_context)
    phase = tf.keras.layers.Dense(
        len(payload["phases"]),
        activation="softmax",
        name="phase",
    )(last_context)

    average_context = tf.keras.layers.GlobalAveragePooling1D(name="quality_temporal_average")(sequence)
    peak_context = tf.keras.layers.GlobalMaxPooling1D(name="quality_temporal_peak")(sequence)
    quality_context = tf.keras.layers.Concatenate(name="quality_motion_context")([
        last_context,
        average_context,
        peak_context,
    ])
    quality_context = tf.keras.layers.Dense(
        max(32, filters),
        activation="relu",
        kernel_regularizer=tf.keras.regularizers.L2(1e-4),
        name="quality_dense",
    )(quality_context)
    quality_context = tf.keras.layers.Dropout(
        max(0.0, min(0.4, dropout)),
        name="quality_dropout",
    )(quality_context)
    quality = tf.keras.layers.Dense(
        len(payload["qualities"]),
        activation="softmax",
        name="quality",
    )(quality_context)

    return tf.keras.Model(
        inputs=inputs,
        outputs={"phase": phase, "quality": quality},
        name="dynamic_weight_shifts_tcn_v3",
    )
