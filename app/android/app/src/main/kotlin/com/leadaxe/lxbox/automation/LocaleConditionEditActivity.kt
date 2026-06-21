package com.leadaxe.lxbox.automation

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.View
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Spinner
import android.widget.TextView

/// §047 Шаг 2 — edit-экран condition-плагина («State → Plugin → L×Box»).
/// Spinner: что проверять (VPN включён / Активная нода = / Активная группа =).
/// Для node/group показывается поле значения. Save → bundle + blurb.
class LocaleConditionEditActivity : Activity() {

    /// (check, человекочитаемая подпись, нужно ли значение).
    private val checks = listOf(
        Triple("vpn-up", "VPN включён", false),
        Triple("active-node", "Активная нода =", true),
        Triple("active-group", "Активная группа =", true),
    )

    private lateinit var spinner: Spinner
    private lateinit var valueInput: EditText
    private lateinit var valueLabel: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "L×Box"

        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        root.addView(TextView(this).apply { text = "Условие L×Box:" })
        spinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@LocaleConditionEditActivity,
                android.R.layout.simple_spinner_dropdown_item,
                checks.map { it.second },
            )
        }
        root.addView(spinner)

        valueLabel = TextView(this).apply {
            text = "Значение:"
            setPadding(0, pad, 0, 0)
            visibility = View.GONE
        }
        root.addView(valueLabel)
        valueInput = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            visibility = View.GONE
        }
        root.addView(valueInput)

        spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                val needsValue = checks[pos].third
                val vis = if (needsValue) View.VISIBLE else View.GONE
                valueLabel.visibility = vis
                valueInput.visibility = vis
            }
            override fun onNothingSelected(p: AdapterView<*>?) {}
        }

        val save = Button(this).apply {
            text = "Сохранить"
            gravity = Gravity.CENTER
            setOnClickListener { onSave() }
        }
        root.addView(save, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply { topMargin = pad })

        prefill()
        setContentView(root)
    }

    private fun prefill() {
        val parsed = LocaleApi.parseCondition(
            intent.getBundleExtra(LocaleApi.EXTRA_BUNDLE),
        ) ?: return
        val (check, equals) = parsed
        val idx = checks.indexOfFirst { it.first == check }
        if (idx >= 0) {
            spinner.setSelection(idx)
            if (checks[idx].third) valueInput.setText(equals ?: "")
        }
    }

    private fun onSave() {
        val pos = spinner.selectedItemPosition
        val (check, blurbLabel, needsValue) = checks[pos]
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
