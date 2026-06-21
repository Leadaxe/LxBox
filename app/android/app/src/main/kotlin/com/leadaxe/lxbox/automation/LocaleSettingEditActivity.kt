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

/// §047 Шаг 2 — edit-экран setting-плагина, который Tasker открывает при
/// «Action → Plugin → L×Box». Нативный Kotlin (не Flutter — изоляция от
/// движка, быстрый cold-start). Spinner команд + условный extra-input + Save.
///
/// На Save: собираем JSON-bundle ([LocaleApi.buildSettingBundle]) + blurb,
/// `setResult(RESULT_OK)`, finish. На back без Save — `RESULT_CANCELED`.
class LocaleSettingEditActivity : Activity() {

    /// (cmd, человекочитаемая подпись, имя extra или null).
    private val commands = listOf(
        Triple("start-vpn", "Включить VPN", null),
        Triple("stop-vpn", "Выключить VPN", null),
        Triple("toggle-vpn", "Переключить VPN", null),
        Triple("switch-node", "Сменить ноду", "tag"),
        Triple("set-group", "Сменить группу", "group"),
        Triple("rebuild-config", "Пересобрать config", null),
        Triple("refresh-subs", "Обновить подписки", null),
        Triple("reset-network", "Сбросить сеть", null),
        Triple("urltest-group", "URLTest группы", "group"),
    )

    private lateinit var spinner: Spinner
    private lateinit var extraInput: EditText
    private lateinit var extraLabel: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        title = "L×Box"

        val pad = (16 * resources.displayMetrics.density).toInt()
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        root.addView(TextView(this).apply { text = "Команда L×Box:" })
        spinner = Spinner(this).apply {
            adapter = ArrayAdapter(
                this@LocaleSettingEditActivity,
                android.R.layout.simple_spinner_dropdown_item,
                commands.map { it.second },
            )
        }
        root.addView(spinner)

        extraLabel = TextView(this).apply {
            setPadding(0, pad, 0, 0)
            visibility = View.GONE
        }
        root.addView(extraLabel)
        extraInput = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_TEXT
            visibility = View.GONE
        }
        root.addView(extraInput)

        spinner.onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
            override fun onItemSelected(p: AdapterView<*>?, v: View?, pos: Int, id: Long) {
                val extraName = commands[pos].third
                if (extraName == null) {
                    extraLabel.visibility = View.GONE
                    extraInput.visibility = View.GONE
                } else {
                    extraLabel.text = "Значение ($extraName):"
                    extraLabel.visibility = View.VISIBLE
                    extraInput.visibility = View.VISIBLE
                }
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

        // Pre-fill при повторном редактировании (host шлёт прошлый bundle).
        prefill()

        setContentView(root)
    }

    private fun prefill() {
        val parsed = LocaleApi.parseSetting(
            intent.getBundleExtra(LocaleApi.EXTRA_BUNDLE),
        ) ?: return
        val (cmd, args) = parsed
        val idx = commands.indexOfFirst { it.first == cmd }
        if (idx >= 0) {
            spinner.setSelection(idx)
            val extraName = commands[idx].third
            if (extraName != null) {
                extraInput.setText(args[extraName]?.toString() ?: "")
            }
        }
    }

    private fun onSave() {
        val pos = spinner.selectedItemPosition
        val (cmd, blurbLabel, extraName) = commands[pos]
        val args = mutableMapOf<String, Any?>()
        var blurb = blurbLabel
        if (extraName != null) {
            val value = extraInput.text.toString().trim()
            args[extraName] = value
            if (value.isNotEmpty()) blurb = "$blurbLabel → $value"
        }
        val data = Intent().apply {
            putExtra(LocaleApi.EXTRA_BUNDLE, LocaleApi.buildSettingBundle(cmd, args))
            putExtra(LocaleApi.EXTRA_STRING_BLURB, blurb)
        }
        setResult(RESULT_OK, data)
        finish()
    }
}
