// grafana.ini:
// [plugins]
//  allow_loading_unsigned_plugins = docker-events-analyzer
// /var/lib/grafana/plugins/docker-events-analyzer
// query:
// {job="docker"} | json | event_type != ""

class DockerEventsPanel {
    constructor(options) {
        this.element = options.element;
        this.data = options.data;
        this.width = options.width;
        this.height = options.height;

        // Initialize event counters
        this.eventTypes = new Map();
        this.containerEvents = new Map();
        this.timelineEvents = [];

        this.render();
    }

    parseDockerEvent(logLine, fallbackTime) {
        try {
            const event = JSON.parse(logLine);
            if (!event || typeof event !== 'object' || Array.isArray(event)) return null;
            let timestamp = event.ts ?? event.timestamp ?? fallbackTime;
            if (event.timeNano != null) timestamp = Number(event.timeNano) / 1e6;
            else if (event.time != null) timestamp = Number(event.time) * 1000;
            else if (typeof timestamp === 'string') timestamp = /^\d+(\.\d+)?$/.test(timestamp) ? Number(timestamp) : Date.parse(timestamp);
            const type = event.Action || event.event || event.type || event.status;
            const container = event.Actor?.Attributes?.name || event.container || event.name || event.id || event.Actor?.ID;
            if (!Number.isFinite(timestamp) || typeof type !== 'string' || !type || typeof container !== 'string' || !container) return null;
            return {
                timestamp,
                type,
                container,
                status: event.status || event.Action,
                details: event.details || event
            };
        } catch (e) {
            return null;
        }
    }

    processData() {
        this.eventTypes.clear();
        this.containerEvents.clear();
        this.timelineEvents = [];

        if (!this.data || !this.data.series || !this.data.series.length) return;

        this.data.series.forEach(series => {
            const timeField = series.fields.find(f => f.type === 'time');
            const logField = series.fields.find(f => f.type === 'string');

            if (!timeField || !logField) return;

            const valueAt = (field, i) => typeof field.values.get === 'function' ? field.values.get(i) : field.values[i];
            for (let i = 0; i < series.length; i++) {
                const event = this.parseDockerEvent(valueAt(logField, i), valueAt(timeField, i));
                if (!event) continue;

                // Count event types
                this.eventTypes.set(event.type,
                    (this.eventTypes.get(event.type) || 0) + 1);

                // Track container events
                if (!this.containerEvents.has(event.container)) {
                    this.containerEvents.set(event.container, []);
                }
                this.containerEvents.get(event.container).push(event);

                // Add to timeline
                this.timelineEvents.push(event);
            }
        });

        // Sort timeline events
        this.timelineEvents.sort((a, b) => a.timestamp - b.timestamp);
        this.containerEvents.forEach(events => events.sort((a, b) => a.timestamp - b.timestamp));
    }

    createEventTypesChart() {
        const chart = document.createElement('div');
        chart.className = 'event-types-chart';
        chart.style.height = '200px';
        chart.style.marginBottom = '20px';

        const barChart = document.createElement('div');
        barChart.style.display = 'flex';
        barChart.style.alignItems = 'flex-end';
        barChart.style.height = '100%';

        const maxValue = Math.max(...Array.from(this.eventTypes.values()));

        this.eventTypes.forEach((count, type) => {
            const bar = document.createElement('div');
            const height = (count / maxValue) * 100;

            bar.style.width = `${100 / this.eventTypes.size}%`;
            bar.style.height = `${height}%`;
            bar.style.backgroundColor = this.getEventColor(type);
            bar.style.margin = '0 2px';
            bar.title = `${type}: ${count}`;

            const label = document.createElement('div');
            label.textContent = type;
            label.style.transform = 'rotate(-45deg)';
            label.style.fontSize = '12px';

            bar.appendChild(label);
            barChart.appendChild(bar);
        });

        chart.appendChild(barChart);
        return chart;
    }

    createContainerList() {
        const list = document.createElement('div');
        list.className = 'container-list';
        list.style.maxHeight = '300px';
        list.style.overflowY = 'auto';

        this.containerEvents.forEach((events, container) => {
            const item = document.createElement('div');
            item.className = 'container-item';
            item.style.padding = '10px';
            item.style.borderBottom = '1px solid #ccc';

            const lastEvent = events[events.length - 1];
            const status = lastEvent.status || 'unknown';

            const heading = document.createElement('div');
            heading.style.display = 'flex';
            heading.style.justifyContent = 'space-between';
            const name = document.createElement('strong');
            name.textContent = container;
            const state = document.createElement('span');
            state.className = `status-${status}`;
            state.textContent = status;
            heading.appendChild(name);
            heading.appendChild(state);
            const last = document.createElement('div');
            last.textContent = `Last event: ${new Date(lastEvent.timestamp).toLocaleString()}`;
            const count = document.createElement('div');
            count.textContent = `Total events: ${events.length}`;
            item.appendChild(heading);
            item.appendChild(last);
            item.appendChild(count);

            list.appendChild(item);
        });

        return list;
    }

    getEventColor(type) {
        const colors = {
            'create': '#4CAF50',
            'start': '#2196F3',
            'stop': '#FFC107',
            'die': '#F44336',
            'destroy': '#9C27B0'
        };
        return colors[type] || '#607D8B';
    }

    render() {
        this.element.innerHTML = '';
        this.processData();

        const container = document.createElement('div');
        container.style.padding = '10px';

        // Add title
        const title = document.createElement('h2');
        title.textContent = 'Docker Events Analysis';
        title.style.marginBottom = '20px';
        container.appendChild(title);

        // Add event types chart
        const chartTitle = document.createElement('h3');
        chartTitle.textContent = 'Event Types Distribution';
        container.appendChild(chartTitle);
        container.appendChild(this.createEventTypesChart());

        // Add container list
        const listTitle = document.createElement('h3');
        listTitle.textContent = 'Container Status';
        container.appendChild(listTitle);
        container.appendChild(this.createContainerList());

        this.element.appendChild(container);

        // Add CSS
        const style = document.createElement('style');
        style.textContent = `
            .status-running { color: #4CAF50; }
            .status-stopped { color: #F44336; }
            .container-item:hover { background-color: rgba(0,0,0,0.1); }
        `;
        this.element.appendChild(style);
    }
}

// Register the panel
window.grafanaBootData = window.grafanaBootData || {};
window.grafanaBootData.plugin = {
    panel: DockerEventsPanel
};
