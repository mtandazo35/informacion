import {
    BaseEntity,
    Entity,
    PrimaryGeneratedColumn,
    Column,
    CreateDateColumn,
    UpdateDateColumn,
    Index,
    ManyToOne,
    JoinColumn,
} from 'typeorm';
import { ResetTimeType } from '../enum/reset-time.enum';
import { DayOfWeek } from '../enum/day-of-week.enum';
import { Plan } from '../../planes/entities/plan.entity';
import { Cliente } from '../../clientes/entities/cliente.entity';

@Entity('token')
@Index('IDX_token_ip_puerto', ['ip', 'puerto'])
@Index('IDX_token_isActive', ['isActive'])
export class Token extends BaseEntity {
    @PrimaryGeneratedColumn('uuid')
    id: string;

    @Column()
    nombreToken: string;

    @Column()
    token: string;

    @Column()
    ip: string;

    @Column({ nullable: true })
    puerto: string;

    @Column({ type: 'timestamp', nullable: true })
    nextResetAt: Date;

    @Column({ type: 'timestamp', nullable: true })
    lastResetAt: Date;

    // ===== RESETEO =====
    @Column({
        type: 'enum',
        enum: ResetTimeType,
    })
    tipoTiempoReseteo: ResetTimeType;

    // Cada cuántas horas
    @Column({ type: 'int', nullable: true })
    intervaloHoras: number;

    // Hora fija (HH:mm)
    @Column({ type: 'time', nullable: true })
    horaReseteo: string;

    // Días de la semana
    @Column({ type: 'simple-array', nullable: true })
    diasSemana: DayOfWeek[];

    // Un día específico de la semana
    @Column({ type: 'enum', enum: DayOfWeek, nullable: true })
    diaSemana: DayOfWeek;

    // Día del mes
    @Column({ type: 'int', nullable: true })
    diaMes: number;

    @Column({ default: true })
    isActive: boolean;

    // Flag de "paquete de seguridad" activo — si true, el token tiene
    // aplicadas todas las blocklists habilitadas globalmente.
    @Column({ default: false })
    seguridadActivada: boolean;

    // Caché del count de blocklists administradas aplicadas a este token
    // (actualizado tras cada assignBlocklists / toggleSeguridad). Evita hacer
    // round-trips al Technitium en cada listado.
    @Column({ type: 'int', default: 0 })
    blocklistCount: number;

    // Reglas totales sumadas de las listas aplicadas. Mostrado como tooltip
    // en la UI.
    @Column({ type: 'int', default: 0 })
    blocklistRulesTotal: number;

    // IDs de blocklists "asignadas" por el usuario al token. Persisten aunque
    // seguridad este desactivada — al activar seguridad se aplican estas (no
    // todas las globalmente habilitadas).
    @Column({ type: 'simple-array', nullable: true })
    assignedBlocklistIds: string[];

    // ============================
    // Cliente / Integración Grafana
    // ============================

    /** Email del cliente (destino de credenciales de Grafana) */
    @Column({ type: 'varchar', nullable: true })
    emailCliente: string | null;

    /** FK al Cliente dueño de este token (nullable para retrocompatibilidad) */
    @Column({ type: 'uuid', nullable: true })
    clienteId: string | null;

    @ManyToOne(() => Cliente, { nullable: true, onDelete: 'SET NULL' })
    @JoinColumn({ name: 'clienteId' })
    cliente: Cliente;

    /** URL del Prometheus del cliente (para crear el data source en Grafana) */
    @Column({ type: 'varchar', nullable: true })
    prometheusUrl: string | null;

    @Column({ type: 'int', nullable: true })
    grafanaOrgId: number | null;

    @Column({ type: 'int', nullable: true })
    grafanaUserId: number | null;

    @Column({ type: 'int', nullable: true })
    diaSuspension: number | null;

    @Column({ type: 'uuid', nullable: true })
    planId: string | null;

    @ManyToOne(() => Plan, { nullable: true, onDelete: 'SET NULL' })
    @JoinColumn({ name: 'planId' })
    plan: Plan | null;

    @Column({ type: 'varchar', nullable: true })
    grafanaUsername: string | null;

    /** Password cifrada con AES-256-GCM (ver common/crypto.ts) */
    @Column({ type: 'varchar', nullable: true })
    grafanaPassword: string | null;

    @Column({ type: 'varchar', nullable: true })
    grafanaDashboardUid: string | null;


    @Column({ type: 'varchar', nullable: true })
    sshHost: string | null;

    @Column({ type: 'int', default: 22 })
    sshPort: number;

    @Column({ type: 'varchar', default: 'root' })
    sshUsername: string;

    @Column({ type: 'varchar', length: 16, default: 'key' })
    sshAuthMethod: 'password' | 'key';

    @Column({ type: 'text', nullable: true })
    sshPassword: string | null;

    @Column({ type: 'text', nullable: true })
    sshPrivateKey: string | null;

    @Column({ type: 'timestamp', nullable: true })
    sshLastTestAt: Date | null;

    @Column({ type: 'varchar', length: 16, default: 'never' })
    sshLastTestStatus: 'never' | 'pending' | 'success' | 'failed';

    @Column({ type: 'text', nullable: true })
    sshLastTestMessage: string | null;

    @Column({ type: 'varchar', length: 32, nullable: true })
    dnsVersion: string | null;

    @Column({ type: 'varchar', length: 32, nullable: true })
    dnsUpdateVersion: string | null;

    @Column({ type: 'boolean', default: false })
    dnsUpdateAvailable: boolean;

    @Column({ type: 'timestamp', nullable: true })
    dnsVersionCheckedAt: Date | null;

    @CreateDateColumn()
    createdAt: Date;

    @UpdateDateColumn()
    updatedAt: Date;
}
