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
import com.leadaxe.lxbox.R
import com.leadaxe.lxbox.vpn.L10n

/// §047 Шаг 2 — edit-экран condition-плагина («State → Plugin → L×Box»).
/// Список проверок сразу (RadioGroup): VPN up / Active node = / Active group =.
/// Для node/group показывается поле значения. Save → bundle + blurb.
class LocaleConditionEditActivity : Activity() {

    /// (check, label-resource, needs value).
    /// §279 — check = wire (Tasker-bundle), label — ресурс (L10n).
    private val checks = listOf(
        Triple("vpn-up", R.string.automation_check_vpn_up, false),
        Triple("active-node", R.string.automation_check_active_node, true),
        Triple("active-group", R.string.automation_check_active_group, true),
    )

    private lateinit var radioGroup: RadioGroup
    private lateinit var valueInput: EditText
    private lateinit var valueLabel: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = L10n.str(this, R.string.app_name)

        val pad = (16 * resources.displayMetrics.density).toInt()
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        content.addView(TextView(this).apply {
            text = L10n.str(this@LocaleConditionEditActivity,
                R.string.automation_condition_prompt)
            setPadding(0, 0, 0, pad / 2)
        })

        radioGroup = RadioGroup(this)
        checks.forEachIndexed { idx, (_, labelRes, _) ->
            radioGroup.addView(RadioButton(this).apply {
                id = idx
                text = L10n.str(this@LocaleConditionEditActivity, labelRes)
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
            text = L10n.str(this@LocaleConditionEditActivity,
                R.string.automation_value_plain)
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
            text = L10n.str(this@LocaleConditionEditActivity, R.string.automation_save)
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
        val (check, labelRes, needsValue) = checks[idx]
        val value = if (needsValue) valueInput.text.toString().trim() else null
        // §279 — блёрб display-only (host матчит по extras): активная локаль.
        val blurbLabel = L10n.str(this, labelRes)
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
