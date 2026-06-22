package com.leadaxe.lxbox.automation

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView

/// §047 Шаг 2 — edit-экран condition-плагина («State → Plugin → L×Box»).
/// Список проверок сразу (RadioGroup): VPN up / Active node = / Active group =.
/// Для node/group показывается поле значения. Save → bundle + blurb.
class LocaleConditionEditActivity : Activity() {

    /// (check, label, needs value).
    private val checks = listOf(
        Triple("vpn-up", "VPN is up", false),
        Triple("active-node", "Active node =", true),
        Triple("active-group", "Active group =", true),
    )

    private lateinit var radioGroup: RadioGroup
    private lateinit var valueInput: EditText
    private lateinit var valueLabel: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "L×Box"

        val pad = (16 * resources.displayMetrics.density).toInt()
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        content.addView(TextView(this).apply {
            text = "L×Box condition:"
            setPadding(0, 0, 0, pad / 2)
        })

        radioGroup = RadioGroup(this)
        checks.forEachIndexed { idx, (_, label, _) ->
            radioGroup.addView(RadioButton(this).apply {
                id = idx
                text = label
                setPadding(0, pad / 3, 0, pad / 3)
            })
        }
        radioGroup.setOnCheckedChangeListener { _, checkedId ->
            val needsValue = checks.getOrNull(checkedId)?.third ?: false
            val vis = if (needsValue) View.VISIBLE else View.GONE
            valueLabel.visibility = vis
            valueInput.visibility = vis
        }
        content.addView(radioGroup)

        valueLabel = TextView(this).apply {
            text = "Value:"
            setPadding(0, pad, 0, 0)
            visibility = View.GONE
        }
        content.addView(valueLabel)
        valueInput = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            visibility = View.GONE
        }
        content.addView(valueInput)

        val save = Button(this).apply {
            text = "Save"
            gravity = Gravity.CENTER
            setOnClickListener { onSave() }
        }
        content.addView(save, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = pad })

        if (!prefill()) radioGroup.check(0)

        setContentView(ScrollView(this).apply { addView(content) })
    }

    private fun prefill(): Boolean {
        val parsed = LocaleApi.parseCondition(
            intent.getBundleExtra(LocaleApi.EXTRA_BUNDLE),
        ) ?: return false
        val (check, equals) = parsed
        val idx = checks.indexOfFirst { it.first == check }
        if (idx < 0) return false
        radioGroup.check(idx)
        if (checks[idx].third) valueInput.setText(equals ?: "")
        return true
    }

    private fun onSave() {
        val checkedId = radioGroup.checkedRadioButtonId
        val idx = if (checkedId in checks.indices) checkedId else 0
        val (check, blurbLabel, needsValue) = checks[idx]
        val value = if (needsValue) valueInput.text.toString().trim() else null
        val blurb = if (needsValue && !value.isNullOrEmpty()) {
            "$blurbLabel $value"
        } else {
            blurbLabel
        }
        val data = Intent().apply {
            putExtra(LocaleApi.EXTRA_BUNDLE, LocaleApi.buildConditionBundle(check, value))
            putExtra(LocaleApi.EXTRA_STRING_BLURB, blurb)
        }
        setResult(RESULT_OK, data)
        finish()
    }
}
